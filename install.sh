#!/usr/bin/env bash
set -Eeuo pipefail

HADOOP_VERSION="2.7.0"
HADOOP_ARCHIVE="hadoop-${HADOOP_VERSION}.tar.gz"
HADOOP_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_ARCHIVE}"
HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-${HADOOP_VERSION}}"
DATA_HOME="${HADOOP_DATA_HOME:-$HOME/hadoopdata/hdfs}"
APP_DIR="${HOME}/hadoop-auto-web"
APP_PORT="${HADOOP_WEB_PORT:-8000}"

log() { printf '\n[HADOOP-AUTO] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; echo "[ERROR] Installation stopped at line $LINENO (exit $rc)." >&2; exit "$rc"' ERR

[[ "$(uname -s)" == Linux ]] || die "Ubuntu/Linux is required."
command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
[[ "$EUID" -ne 0 ]] || die "Run as your normal Ubuntu user, not with sudo."
command -v sudo >/dev/null 2>&1 || die "sudo is required."
sudo -v

log "Updating Ubuntu package information..."
sudo apt-get update

JAVA_MAJOR=""
if command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(readlink -f "$(command -v java)")"
  JAVA_MAJOR="$("$JAVA_BIN" -version 2>&1 | awk -F '[".]' '/version/ {if ($2=="1") print $3; else print $2; exit}')"
fi
if [[ "$JAVA_MAJOR" != "8" ]]; then
  log "Installing Java 8..."
  apt-cache show openjdk-8-jdk >/dev/null 2>&1 || die "Java 8 JDK is unavailable in the configured repositories. Ask your lab administrator to provide Java 8."
  sudo apt-get install -y openjdk-8-jdk
fi
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
[[ -x "$JAVA_HOME/bin/java" ]] || die "Java JDK could not be located."

log "Installing/checking OpenSSH..."
dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed' || sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh

log "Configuring passwordless localhost SSH..."
install -d -m 700 "$HOME/.ssh"
[[ -f "$HOME/.ssh/id_rsa" ]] || ssh-keygen -q -t rsa -b 3072 -N '' -f "$HOME/.ssh/id_rsa"
touch "$HOME/.ssh/authorized_keys" "$HOME/.ssh/known_hosts"
chmod 600 "$HOME/.ssh/authorized_keys"
grep -qxF "$(cat "$HOME/.ssh/id_rsa.pub")" "$HOME/.ssh/authorized_keys" || cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
ssh-keyscan -H localhost 127.0.0.1 2>/dev/null >> "$HOME/.ssh/known_hosts" || true

log "Locating/downloading Hadoop ${HADOOP_VERSION}..."
if [[ ! -x "$HADOOP_HOME/bin/hdfs" ]]; then
  for candidate in "$HOME/hadoop-${HADOOP_VERSION}" "/usr/local/hadoop-${HADOOP_VERSION}" "/opt/hadoop-${HADOOP_VERSION}"; do
    if [[ -x "$candidate/bin/hdfs" ]]; then HADOOP_HOME="$candidate"; break; fi
  done
fi
if [[ ! -x "$HADOOP_HOME/bin/hdfs" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rc=$?; rm -rf "${TMP_DIR:-}"; if (( rc != 0 )); then echo "[ERROR] Installer failed (exit $rc)." >&2; fi; exit "$rc"' EXIT
  curl -fL "$HADOOP_URL" -o "$TMP_DIR/$HADOOP_ARCHIVE"
  tar -xzf "$TMP_DIR/$HADOOP_ARCHIVE" -C "$HOME"
  HADOOP_HOME="$HOME/hadoop-${HADOOP_VERSION}"
  rm -rf "$TMP_DIR"
  trap - ERR
fi
[[ -x "$HADOOP_HOME/bin/hdfs" ]] || die "Hadoop executable missing at $HADOOP_HOME."

log "Writing Hadoop configuration..."
CONF_DIR="$HADOOP_HOME/etc/hadoop"
mkdir -p "$DATA_HOME/namenode" "$DATA_HOME/datanode"
touch "$HOME/.bashrc"
for f in hadoop-env.sh core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do
  if [[ -f "$CONF_DIR/$f" ]] && ! grep -q 'HADOOP_AUTO_MANAGED' "$CONF_DIR/$f"; then
    [[ -e "$CONF_DIR/$f.pre-hadoop-auto" ]] || cp "$CONF_DIR/$f" "$CONF_DIR/$f.pre-hadoop-auto"
  fi
done
if grep -q '^export JAVA_HOME=' "$CONF_DIR/hadoop-env.sh"; then
  sed -i "s|^export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|" "$CONF_DIR/hadoop-env.sh"
else
  printf '\n# HADOOP_AUTO_MANAGED\nexport JAVA_HOME=%s\n' "$JAVA_HOME" >> "$CONF_DIR/hadoop-env.sh"
fi
cat > "$CONF_DIR/core-site.xml" <<EOF
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property></configuration>
EOF
cat > "$CONF_DIR/hdfs-site.xml" <<EOF
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration>
<property><name>dfs.replication</name><value>1</value></property>
<property><name>dfs.namenode.name.dir</name><value>file://${DATA_HOME}/namenode</value></property>
<property><name>dfs.datanode.data.dir</name><value>file://${DATA_HOME}/datanode</value></property>
</configuration>
EOF
cat > "$CONF_DIR/mapred-site.xml" <<'EOF'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>mapreduce.framework.name</name><value>yarn</value></property></configuration>
EOF
cat > "$CONF_DIR/yarn-site.xml" <<'EOF'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration><property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property></configuration>
EOF

for line in "export JAVA_HOME=$JAVA_HOME" "export HADOOP_HOME=$HADOOP_HOME" 'export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"'; do
  grep -qxF "$line" "$HOME/.bashrc" || printf '%s\n' "$line" >> "$HOME/.bashrc"
done
export JAVA_HOME HADOOP_HOME
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

log "Checking NameNode metadata (existing HDFS data will not be formatted)..."
if [[ -f "$DATA_HOME/namenode/current/VERSION" ]]; then
  log "Existing NameNode metadata found; preserving it."
elif [[ -n "$(find "$DATA_HOME/namenode" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  die "NameNode directory is non-empty but has no VERSION metadata. Refusing to format it."
else
  log "Initializing a new NameNode for the first time..."
  "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive
fi

log "Starting HDFS and YARN..."
pgrep -f 'org.apache.hadoop.hdfs.server.namenode.NameNode' >/dev/null || "$HADOOP_HOME/sbin/start-dfs.sh"
pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null || "$HADOOP_HOME/sbin/start-yarn.sh"

log "Installing the WordCount web dashboard..."
mkdir -p "$APP_DIR"
log "Downloading WordCount web application from GitHub..."

WEBAPP_URL="https://raw.githubusercontent.com/ragav2730/hadoop-auto/main/webapp.py"

curl -fL --retry 3 "$WEBAPP_URL" -o "$APP_DIR/webapp.py"

python3 -m py_compile "$APP_DIR/webapp.py" || die "Invalid web application file."
cat > "$APP_DIR/start-dashboard.sh" <<EOF
#!/usr/bin/env bash
export JAVA_HOME="$JAVA_HOME"
export HADOOP_HOME="$HADOOP_HOME"
export PATH="\$PATH:\$JAVA_HOME/bin:\$HADOOP_HOME/bin:\$HADOOP_HOME/sbin"
cd "$APP_DIR"
exec python3 webapp.py --host 127.0.0.1 --port "$APP_PORT"
EOF
chmod +x "$APP_DIR/start-dashboard.sh"

# Replace only this user's dashboard process if it is already running.
if [[ -f "$APP_DIR/dashboard.pid" ]] && kill -0 "$(cat "$APP_DIR/dashboard.pid")" 2>/dev/null; then
  kill "$(cat "$APP_DIR/dashboard.pid")" || true
fi
nohup "$APP_DIR/start-dashboard.sh" > "$APP_DIR/dashboard.log" 2>&1 &
echo $! > "$APP_DIR/dashboard.pid"
sleep 2

log "Checking Hadoop processes..."
jps || true
printf '\nSETUP FINISHED\n'
printf 'NameNode UI:       http://localhost:50070\n'
printf 'YARN Resource UI:  http://localhost:8088\n'
printf 'WordCount UI:      http://localhost:%s\n' "$APP_PORT"
printf 'Dashboard log:     %s/dashboard.log\n' "$APP_DIR"
printf '\nOpen the WordCount UI in your browser. Upload a .txt file and click Run WordCount.\n'
