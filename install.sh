#!/usr/bin/env bash
# Hadoop Auto installer/repairer for Ubuntu + Hadoop 2.7.0.
# Safe policy: backs up configs; never deletes HDFS data or reformats an existing NameNode.
set -Eeuo pipefail
HADOOP_VERSION="2.7.0"
HADOOP_ARCHIVE="hadoop-${HADOOP_VERSION}.tar.gz"
HADOOP_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_ARCHIVE}"
HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-${HADOOP_VERSION}}"
DATA_HOME="${HADOOP_DATA_HOME:-$HOME/hadoopdata/hdfs}"
APP_DIR="$HOME/hadoop-auto-web"
APP_PORT="${HADOOP_WEB_PORT:-8000}"
TMP_DIR=""
log(){ printf '\n[HADOOP-AUTO] %s\n' "$*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
on_error(){ rc=$?; echo "[ERROR] Installer failed near line ${BASH_LINENO[0]:-unknown} (exit $rc)." >&2; exit "$rc"; }
trap cleanup EXIT
trap on_error ERR
[[ "$(uname -s)" == Linux ]] || die "Ubuntu/Linux is required."
command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
[[ "$EUID" -ne 0 ]] || die "Run as your normal Ubuntu user, not with sudo."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
sudo -v
log "Installing/checking required tools..."
sudo apt-get update
sudo apt-get install -y curl openssh-server python3 procps
sudo systemctl enable --now ssh
JAVA_MAJOR=""
if command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(readlink -f "$(command -v java)")"
  JAVA_MAJOR="$("$JAVA_BIN" -version 2>&1 | awk -F '[".]' '/version/ {if ($2=="1") print $3; else print $2; exit}')"
fi
if [[ "$JAVA_MAJOR" != "8" ]]; then
  log "Java 8 is required for Hadoop 2.7.0. Installing OpenJDK 8..."
  apt-cache show openjdk-8-jdk >/dev/null 2>&1 || die "OpenJDK 8 is unavailable in configured repositories. Ask the lab administrator to install Java 8; existing Hadoop data is untouched."
  sudo apt-get install -y openjdk-8-jdk
fi
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
[[ -x "$JAVA_HOME/bin/java" ]] || die "Could not locate Java 8."
log "Configuring passwordless localhost SSH..."
install -d -m 700 "$HOME/.ssh"
[[ -f "$HOME/.ssh/id_rsa" ]] || ssh-keygen -q -t rsa -b 3072 -N '' -f "$HOME/.ssh/id_rsa"
touch "$HOME/.ssh/authorized_keys" "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$(cat "$HOME/.ssh/id_rsa.pub")" "$HOME/.ssh/authorized_keys" || cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
ssh-keyscan -H localhost 127.0.0.1 2>/dev/null >> "$HOME/.ssh/known_hosts" || true
ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost 'echo SSH_OK' >/dev/null || die "Passwordless localhost SSH failed. Check SSH service and permissions."
log "Locating Hadoop ${HADOOP_VERSION}..."
if [[ ! -x "$HADOOP_HOME/bin/hdfs" ]]; then
  for candidate in "$HOME/hadoop-${HADOOP_VERSION}" "/usr/local/hadoop-${HADOOP_VERSION}" "/opt/hadoop-${HADOOP_VERSION}"; do
    if [[ -x "$candidate/bin/hdfs" ]]; then HADOOP_HOME="$candidate"; break; fi
  done
fi
if [[ ! -x "$HADOOP_HOME/bin/hdfs" ]]; then
  TMP_DIR="$(mktemp -d)"
  curl -fL --retry 3 "$HADOOP_URL" -o "$TMP_DIR/$HADOOP_ARCHIVE"
  tar -xzf "$TMP_DIR/$HADOOP_ARCHIVE" -C "$HOME"
  HADOOP_HOME="$HOME/hadoop-${HADOOP_VERSION}"
fi
[[ -x "$HADOOP_HOME/bin/hdfs" ]] || die "Hadoop executable not found at $HADOOP_HOME."
CONF_DIR="$HADOOP_HOME/etc/hadoop"
mkdir -p "$DATA_HOME/namenode" "$DATA_HOME/datanode"
touch "$HOME/.bashrc"
log "Backing up existing Hadoop configuration before repair..."
for f in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml hadoop-env.sh; do
  if [[ -f "$CONF_DIR/$f" ]] && ! grep -q 'HADOOP_AUTO_MANAGED' "$CONF_DIR/$f"; then
    backup="$CONF_DIR/$f.pre-hadoop-auto"
    if [[ ! -e "$backup" ]]; then cp -a "$CONF_DIR/$f" "$backup"; log "Backed up $f."; fi
  fi
done
if grep -q '^export JAVA_HOME=' "$CONF_DIR/hadoop-env.sh"; then
  sed -i "s|^export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|" "$CONF_DIR/hadoop-env.sh"
else
  printf '\n# HADOOP_AUTO_MANAGED\nexport JAVA_HOME=%s\n' "$JAVA_HOME" >> "$CONF_DIR/hadoop-env.sh"
fi
cat > "$CONF_DIR/core-site.xml" <<EOF2
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property></configuration>
EOF2
cat > "$CONF_DIR/hdfs-site.xml" <<EOF2
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration>
<property><name>dfs.replication</name><value>1</value></property>
<property><name>dfs.namenode.name.dir</name><value>file://${DATA_HOME}/namenode</value></property>
<property><name>dfs.datanode.data.dir</name><value>file://${DATA_HOME}/datanode</value></property>
</configuration>
EOF2
cat > "$CONF_DIR/mapred-site.xml" <<'EOF2'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>mapreduce.framework.name</name><value>yarn</value></property></configuration>
EOF2
cat > "$CONF_DIR/yarn-site.xml" <<'EOF2'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property></configuration>
EOF2
for line in "export JAVA_HOME=$JAVA_HOME" "export HADOOP_HOME=$HADOOP_HOME" 'export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"'; do
  grep -qxF "$line" "$HOME/.bashrc" || printf '%s\n' "$line" >> "$HOME/.bashrc"
done
export JAVA_HOME HADOOP_HOME
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"
log "Checking NameNode metadata safely..."
if [[ -f "$DATA_HOME/namenode/current/VERSION" ]]; then
  log "Existing NameNode metadata found; preserving it."
elif [[ -n "$(find "$DATA_HOME/namenode" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  die "NameNode directory is non-empty but has no VERSION metadata. Refusing to format/delete it; administrator inspection required."
else
  log "No NameNode metadata found; initializing a new HDFS namespace."
  "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive
fi
log "Starting missing Hadoop daemons..."
pgrep -f 'org.apache.hadoop.hdfs.server.namenode.NameNode' >/dev/null || "$HADOOP_HOME/sbin/start-dfs.sh"
pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null || "$HADOOP_HOME/sbin/start-yarn.sh"
log "Verifying HDFS responds..."
HDFS_OK=0
for attempt in {1..12}; do
  if "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /user1 >/dev/null 2>&1; then HDFS_OK=1; break; fi
  sleep 5
done
[[ "$HDFS_OK" -eq 1 ]] || die "HDFS is not responding. Check $HADOOP_HOME/logs. Existing data was not formatted."
pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null || die "YARN ResourceManager did not start. Check $HADOOP_HOME/logs."
log "Creating/updating terminal WordCount runner..."
cat > "$HOME/run-wordcount.sh" <<'WORDCOUNT'
#!/usr/bin/env bash
set -Eeuo pipefail
INPUT="${1:-}"
if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
  echo "Usage: bash ~/run-wordcount.sh <text-file>"
  echo "Example: bash ~/run-wordcount.sh ~/file1.txt"
  exit 1
fi
HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-2.7.0}"
JAR="$HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-2.7.0.jar"
[[ -f "$JAR" ]] || { echo "WordCount JAR not found: $JAR"; exit 1; }
HDFS_INPUT="/user1/wordcount/input_$(date +%s)_$$"
HDFS_OUTPUT="/user1/wordcount/output_$(date +%s)_$$"
echo "[1/3] Uploading input file..."
hdfs dfs -mkdir -p "$HDFS_INPUT"
hdfs dfs -put "$INPUT" "$HDFS_INPUT/"
echo "[2/3] Running MapReduce WordCount..."
hadoop jar "$JAR" wordcount "$HDFS_INPUT" "$HDFS_OUTPUT"
echo "[3/3] Word frequencies:"
echo "--------------------------------"
hdfs dfs -cat "$HDFS_OUTPUT/part-r-00000"
echo "--------------------------------"
echo "WordCount completed successfully."
WORDCOUNT
chmod +x "$HOME/run-wordcount.sh"
log "Installing/updating optional WordCount dashboard..."
mkdir -p "$APP_DIR"
WEBAPP_URL="https://raw.githubusercontent.com/ragav2730/hadoop-auto/main/webapp.py"
if curl -fL --retry 3 "$WEBAPP_URL" -o "$APP_DIR/webapp.py" && python3 -m py_compile "$APP_DIR/webapp.py"; then
  cat > "$APP_DIR/start-dashboard.sh" <<EOF2
#!/usr/bin/env bash
export JAVA_HOME="$JAVA_HOME"
export HADOOP_HOME="$HADOOP_HOME"
export PATH="\$PATH:\$JAVA_HOME/bin:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin"
cd "$APP_DIR"
exec python3 webapp.py --host 127.0.0.1 --port "$APP_PORT"
EOF2
  chmod +x "$APP_DIR/start-dashboard.sh"
  if [[ -f "$APP_DIR/dashboard.pid" ]]; then
    oldpid="$(cat "$APP_DIR/dashboard.pid" 2>/dev/null || true)"
    [[ ! "$oldpid" =~ ^[0-9]+$ ]] || ! kill -0 "$oldpid" 2>/dev/null || kill "$oldpid" || true
  fi
  nohup "$APP_DIR/start-dashboard.sh" > "$APP_DIR/dashboard.log" 2>&1 &
  echo $! > "$APP_DIR/dashboard.pid"
  sleep 2
  if kill -0 "$(cat "$APP_DIR/dashboard.pid")" 2>/dev/null; then log "Dashboard started at http://localhost:$APP_PORT"; else log "Dashboard did not stay running; see $APP_DIR/dashboard.log. Terminal WordCount remains available."; fi
else
  log "Dashboard download/validation failed; skipped dashboard. Terminal WordCount remains available."
fi
log "Final process check..."
jps || true
printf '\nSETUP FINISHED\nNameNode UI:       http://localhost:50070\nYARN UI:           http://localhost:8088\nWordCount UI:      http://localhost:%s\nTerminal runner:   bash ~/run-wordcount.sh ~/file1.txt\n' "$APP_PORT"
printf '\nExisting HDFS data was preserved; no existing namespace was reformatted.\n'
