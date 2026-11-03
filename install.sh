#!/usr/bin/env bash
# Hadoop 2.7.0 single-node lab installer + cautious repair.
# Supports the lab's GREP and WordCount MapReduce examples.
# It never deletes HDFS data and never reformats an existing NameNode.

set -Eeuo pipefail

VERSION="2.7.0"
ARCHIVE="hadoop-${VERSION}.tar.gz"
URL="https://archive.apache.org/dist/hadoop/common/hadoop-${VERSION}/${ARCHIVE}"
HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-${VERSION}}"
DATA_HOME="${HADOOP_DATA_HOME:-$HOME/hadoopdata/hdfs}"
APP_DIR="$HOME/hadoop-auto-web"
JAVA_HOME=""
TMP_DIR=""

log(){ printf '\n[HADOOP-AUTO] %s\n' "$*"; }
fail(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'rc=$?; echo "[ERROR] Failed near line ${BASH_LINENO[0]:-unknown} (exit $rc). See the message above." >&2; exit "$rc"' ERR

[[ "$(uname -s)" == Linux ]] || fail "Ubuntu/Linux is required."
command -v apt-get >/dev/null || fail "apt-get is required."
[[ "$EUID" -ne 0 ]] || fail "Run as your normal Ubuntu user, not with sudo."
command -v sudo >/dev/null || fail "sudo is required."
sudo -v

log "Installing required utilities and SSH..."
sudo apt-get update
sudo apt-get install -y curl openssh-server python3 procps
sudo systemctl enable --now ssh

log "Checking Java compatibility..."
JAVA_MAJOR=""
if command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(readlink -f "$(command -v java)")"
  JAVA_MAJOR="$("$JAVA_BIN" -version 2>&1 | awk -F '[".]' '/version/ {if ($2=="1") print $3; else print $2; exit}')"
fi
if [[ "$JAVA_MAJOR" != "8" ]]; then
  apt-cache show openjdk-8-jdk >/dev/null 2>&1 || fail "This Hadoop 2.7.0 setup requires Java 8, but OpenJDK 8 is unavailable in this Ubuntu repository. Ask the lab administrator to install Java 8. No HDFS data was changed."
  sudo apt-get install -y openjdk-8-jdk
fi
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
[[ -x "$JAVA_HOME/bin/java" ]] || fail "Java 8 JDK was not found."

log "Configuring passwordless localhost SSH..."
install -d -m 700 "$HOME/.ssh"
if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
  ssh-keygen -q -t rsa -b 3072 -N '' -f "$HOME/.ssh/id_rsa"
fi
touch "$HOME/.ssh/authorized_keys" "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$(cat "$HOME/.ssh/id_rsa.pub")" "$HOME/.ssh/authorized_keys" || cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
ssh-keyscan -H localhost 127.0.0.1 2>/dev/null >> "$HOME/.ssh/known_hosts" || true
ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost 'true' >/dev/null || fail "Localhost SSH authentication failed. Check SSH service and ~/.ssh permissions."

log "Finding Hadoop $VERSION..."
if [[ ! -x "$HADOOP_HOME/bin/hdfs" ]]; then
  for p in "$HOME/hadoop-$VERSION" "/usr/local/hadoop-$VERSION" "/opt/hadoop-$VERSION"; do
    if [[ -x "$p/bin/hdfs" ]]; then HADOOP_HOME="$p"; break; fi
  done
fi
if [[ ! -x "$HADOOP_HOME/bin/hdfs" ]]; then
  TMP_DIR="$(mktemp -d)"
  curl -fL --retry 3 "$URL" -o "$TMP_DIR/$ARCHIVE"
  tar -xzf "$TMP_DIR/$ARCHIVE" -C "$HOME"
  HADOOP_HOME="$HOME/hadoop-$VERSION"
fi
[[ -x "$HADOOP_HOME/bin/hdfs" ]] || fail "Hadoop executable not found."

CONF="$HADOOP_HOME/etc/hadoop"
mkdir -p "$DATA_HOME/namenode" "$DATA_HOME/datanode"
touch "$HOME/.bashrc"

log "Backing up pre-existing configuration before applying lab settings..."
for f in core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml hadoop-env.sh; do
  if [[ -f "$CONF/$f" ]] && ! grep -q 'HADOOP_AUTO_MANAGED' "$CONF/$f"; then
    [[ -e "$CONF/$f.pre-hadoop-auto" ]] || cp -a "$CONF/$f" "$CONF/$f.pre-hadoop-auto"
  fi
done

if grep -q '^export JAVA_HOME=' "$CONF/hadoop-env.sh"; then
  sed -i "s|^export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|" "$CONF/hadoop-env.sh"
else
  printf '\n# HADOOP_AUTO_MANAGED\nexport JAVA_HOME=%s\n' "$JAVA_HOME" >> "$CONF/hadoop-env.sh"
fi

cat > "$CONF/core-site.xml" <<EOF
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property></configuration>
EOF
cat > "$CONF/hdfs-site.xml" <<EOF
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration>
<property><name>dfs.replication</name><value>1</value></property>
<property><name>dfs.namenode.name.dir</name><value>file://${DATA_HOME}/namenode</value></property>
<property><name>dfs.datanode.data.dir</name><value>file://${DATA_HOME}/datanode</value></property>
</configuration>
EOF
cat > "$CONF/mapred-site.xml" <<'EOF'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>mapreduce.framework.name</name><value>yarn</value></property></configuration>
EOF
cat > "$CONF/yarn-site.xml" <<'EOF'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property></configuration>
EOF

for line in "export JAVA_HOME=$JAVA_HOME" "export HADOOP_HOME=$HADOOP_HOME" 'export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"'; do
  grep -qxF "$line" "$HOME/.bashrc" || printf '%s\n' "$line" >> "$HOME/.bashrc"
done
export JAVA_HOME HADOOP_HOME
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

log "Checking NameNode metadata. Existing HDFS data will not be formatted."
if [[ -f "$DATA_HOME/namenode/current/VERSION" ]]; then
  log "Existing NameNode metadata found; preserving it."
elif [[ -n "$(find "$DATA_HOME/namenode" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "NameNode directory is non-empty but has no current/VERSION metadata. Installer refuses to format or delete it. Administrator inspection is required."
else
  log "First-time HDFS initialization..."
  "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive
fi

log "Starting missing HDFS/YARN daemons..."
if ! pgrep -f 'org.apache.hadoop.hdfs.server.namenode.NameNode' >/dev/null; then
  "$HADOOP_HOME/sbin/start-dfs.sh"
else
  log "NameNode process already exists."
fi
if ! pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null; then
  "$HADOOP_HOME/sbin/start-yarn.sh"
else
  log "ResourceManager process already exists."
fi

log "Waiting for HDFS to respond..."
HDFS_READY=0
for n in {1..12}; do
  if "$HADOOP_HOME/bin/hdfs" dfs -mkdir -p /user1 >/dev/null 2>&1; then HDFS_READY=1; break; fi
  sleep 5
done
[[ "$HDFS_READY" -eq 1 ]] || fail "HDFS daemons did not become ready. Inspect $HADOOP_HOME/logs. Data was not formatted or deleted."
pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null || fail "YARN ResourceManager is not running. Inspect $HADOOP_HOME/logs."

log "Installing the lab runner (GREP + WordCount)..."
cat > "$HOME/hadoop-lab.sh" <<'LABRUN'
#!/usr/bin/env bash
set -Eeuo pipefail
HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-2.7.0}"
JAR="$HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-2.7.0.jar"
[[ -f "$JAR" ]] || { echo "Hadoop examples JAR not found: $JAR"; exit 1; }
if [[ $# -lt 2 ]]; then
  echo "Usage:"
  echo "  bash ~/hadoop-lab.sh wordcount <local-text-file>"
  echo "  bash ~/hadoop-lab.sh grep <local-text-file> <regex>"
  echo "Examples:"
  echo "  bash ~/hadoop-lab.sh wordcount ~/file1.txt"
  echo "  bash ~/hadoop-lab.sh grep ~/file1.txt 'hadoop'"
  exit 2
fi
MODE="$1"
LOCAL_INPUT="$2"
[[ -f "$LOCAL_INPUT" ]] || { echo "Input file not found: $LOCAL_INPUT"; exit 2; }
case "$MODE" in wordcount|grep) ;; *) echo "Choose wordcount or grep."; exit 2;; esac
if ! hdfs dfs -test -d /user1 >/dev/null 2>&1; then
  echo "HDFS is not responding. Start Hadoop with: start-dfs.sh && start-yarn.sh"
  exit 3
fi
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
HDFS_INPUT="/user1/lab-input-$RUN_ID"
HDFS_OUTPUT="/user1/lab-${MODE}-output-$RUN_ID"
echo "[1/3] Uploading input to HDFS: $HDFS_INPUT"
hdfs dfs -mkdir -p "$HDFS_INPUT"
hdfs dfs -put "$LOCAL_INPUT" "$HDFS_INPUT/"
echo "[2/3] Running $MODE MapReduce job..."
if [[ "$MODE" == "wordcount" ]]; then
  hadoop jar "$JAR" wordcount "$HDFS_INPUT" "$HDFS_OUTPUT"
else
  REGEX="${3:-}"
  [[ -n "$REGEX" ]] || { echo "For GREP, provide a regular expression."; exit 2; }
  hadoop jar "$JAR" grep "$HDFS_INPUT" "$HDFS_OUTPUT" "$REGEX"
fi
echo "[3/3] Result ($HDFS_OUTPUT):"
echo "----------------------------------------"
hdfs dfs -cat "$HDFS_OUTPUT"/part-* 2>/dev/null || hdfs dfs -ls "$HDFS_OUTPUT"
echo "----------------------------------------"
echo "SUCCESS. This run used a fresh output directory; previous results were left untouched."
LABRUN
chmod +x "$HOME/hadoop-lab.sh"
cat > "$HOME/run-wordcount.sh" <<'WORDCOUNTWRAPPER'
#!/usr/bin/env bash
exec "$HOME/hadoop-lab.sh" wordcount "$@"
WORDCOUNTWRAPPER
chmod +x "$HOME/run-wordcount.sh"

log "Installing/updating optional web dashboard..."
mkdir -p "$APP_DIR"
WEBAPP_URL="https://raw.githubusercontent.com/ragav2730/hadoop-auto/main/webapp.py"
if curl -fL --retry 3 "$WEBAPP_URL" -o "$APP_DIR/webapp.py" && python3 -m py_compile "$APP_DIR/webapp.py"; then
  cat > "$APP_DIR/start-dashboard.sh" <<EOF
#!/usr/bin/env bash
export JAVA_HOME="$JAVA_HOME"
export HADOOP_HOME="$HADOOP_HOME"
export PATH="\\$PATH:\\$JAVA_HOME/bin:\\$HADOOP_HOME/bin:\\$HADOOP_HOME/sbin"
cd "$APP_DIR"
exec python3 webapp.py --host 127.0.0.1 --port "${HADOOP_WEB_PORT:-8000}"
EOF
  chmod +x "$APP_DIR/start-dashboard.sh"
  if [[ -f "$APP_DIR/dashboard.pid" ]]; then
    oldpid="$(cat "$APP_DIR/dashboard.pid" 2>/dev/null || true)"
    if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then kill "$oldpid" || true; fi
  fi
  nohup "$APP_DIR/start-dashboard.sh" > "$APP_DIR/dashboard.log" 2>&1 &
  echo $! > "$APP_DIR/dashboard.pid"
  sleep 2
  if kill -0 "$(cat "$APP_DIR/dashboard.pid")" 2>/dev/null; then
    log "Dashboard running at http://localhost:${HADOOP_WEB_PORT:-8000}"
  else
    log "Dashboard did not stay running; see $APP_DIR/dashboard.log. Terminal runner remains installed."
  fi
else
  log "Dashboard could not be installed/validated. Terminal GREP and WordCount runners are still available."
fi

log "Final daemon check..."
jps || true
printf '\nINSTALLATION / REPAIR FINISHED\n'
printf 'NameNode UI:       http://localhost:50070\n'
printf 'YARN UI:           http://localhost:8088\n'
printf 'WordCount UI:      http://localhost:${HADOOP_WEB_PORT:-8000}\n'
printf 'WordCount:         bash ~/hadoop-lab.sh wordcount ~/file1.txt\n'
printf 'GREP:              bash ~/hadoop-lab.sh grep ~/file1.txt hadoop\n'
printf '\nHDFS data was preserved. No existing NameNode namespace was reformatted.\n'
