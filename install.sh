#!/usr/bin/env bash
set -Eeuo pipefail

HADOOP_VERSION="2.7.0"
HADOOP_ARCHIVE="hadoop-${HADOOP_VERSION}.tar.gz"
HADOOP_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_ARCHIVE}"
HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-${HADOOP_VERSION}}"
DATA_HOME="${HADOOP_DATA_HOME:-$HOME/hadoopdata/hdfs}"

log() { printf '\n\033[1;34m[HADOOP-AUTO]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Installation stopped at line $LINENO. Review the message above; no NameNode format was forced."' ERR

[[ "$(uname -s)" == Linux ]] || die "This installer supports Ubuntu/Linux only."
command -v apt-get >/dev/null 2>&1 || die "apt-get was not found. This script is intended for Ubuntu/Debian-based lab PCs."

log "Checking administrator access..."
if [[ "$EUID" -eq 0 ]]; then
  die "Do not run this script with sudo. Run it as your normal Ubuntu user; it will request sudo only when required."
fi
command -v sudo >/dev/null 2>&1 || die "sudo is not installed. Ask your lab administrator to install it."
sudo -v || die "Administrator permission was denied. Ask your lab administrator for sudo access."

log "Updating package information..."
sudo apt-get update

# Hadoop 2.7.0 in this lab manual is configured for Java 8.
if command -v java >/dev/null 2>&1; then
  JAVA_BIN="$(readlink -f "$(command -v java)")"
  JAVA_MAJOR="$("$JAVA_BIN" -version 2>&1 | awk -F '[".]' '/version/ { if ($2 == "1") print $3; else print $2; exit }')"
else
  JAVA_MAJOR=""
fi
if [[ "$JAVA_MAJOR" != "8" ]]; then
  log "Java 8 is required by this Hadoop 2.7.0 lab setup."
  if apt-cache show openjdk-8-jdk >/dev/null 2>&1; then
    sudo apt-get install -y openjdk-8-jdk
  else
    die "Java 8 is not installed and openjdk-8-jdk is unavailable in this Ubuntu release's configured repositories. Ask the lab administrator to provide a Java 8 JDK or enable an approved repository; this installer will not silently substitute a different Java version."
  fi
fi
JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
[[ -x "$JAVA_HOME/bin/java" ]] || die "Could not locate a complete JDK at JAVA_HOME=$JAVA_HOME."

log "Checking OpenSSH server..."
if ! dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
  sudo apt-get install -y openssh-server
fi
sudo systemctl enable ssh
sudo systemctl start ssh

log "Configuring passwordless localhost SSH..."
install -d -m 700 "$HOME/.ssh"
if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
  ssh-keygen -q -t rsa -b 3072 -N '' -f "$HOME/.ssh/id_rsa"
fi
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qxF "$(cat "$HOME/.ssh/id_rsa.pub")" "$HOME/.ssh/authorized_keys"; then
  cat "$HOME/.ssh/id_rsa.pub" >> "$HOME/.ssh/authorized_keys"
fi
touch "$HOME/.ssh/known_hosts"
ssh-keyscan -H localhost 127.0.0.1 2>/dev/null >> "$HOME/.ssh/known_hosts" || true

log "Locating or downloading Hadoop ${HADOOP_VERSION}..."
if [[ ! -d "$HADOOP_HOME" ]]; then
  # Reuse a matching existing extraction before downloading.
  for candidate in "$HOME/hadoop-${HADOOP_VERSION}" "/usr/local/hadoop-${HADOOP_VERSION}" "/opt/hadoop-${HADOOP_VERSION}"; do
    if [[ -d "$candidate" ]]; then HADOOP_HOME="$candidate"; break; fi
  done
fi
if [[ ! -d "$HADOOP_HOME" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT
  if command -v curl >/dev/null 2>&1; then curl -fL "$HADOOP_URL" -o "$TMP_DIR/$HADOOP_ARCHIVE"; else sudo apt-get install -y wget; wget -O "$TMP_DIR/$HADOOP_ARCHIVE" "$HADOOP_URL"; fi
  tar -xzf "$TMP_DIR/$HADOOP_ARCHIVE" -C "$HOME"
  HADOOP_HOME="$HOME/hadoop-${HADOOP_VERSION}"
fi
[[ -x "$HADOOP_HOME/bin/hdfs" ]] || die "Hadoop directory exists but does not contain bin/hdfs: $HADOOP_HOME"

log "Backing up and writing Hadoop configuration..."
CONF_DIR="$HADOOP_HOME/etc/hadoop"
[[ -d "$CONF_DIR" ]] || die "Missing Hadoop configuration directory: $CONF_DIR"
backup_file() { local f="$1"; if [[ -f "$f" ]] && ! grep -q 'HADOOP_AUTO_MANAGED' "$f"; then cp -n "$f" "$f.pre-hadoop-auto"; fi; }
for f in hadoop-env.sh core-site.xml hdfs-site.xml mapred-site.xml yarn-site.xml; do backup_file "$CONF_DIR/$f"; done

# Keep a clear marker so reruns can safely replace only files managed by this installer.
if ! grep -q 'HADOOP_AUTO_MANAGED' "$CONF_DIR/hadoop-env.sh"; then
  printf '\n# HADOOP_AUTO_MANAGED\n' >> "$CONF_DIR/hadoop-env.sh"
fi
if grep -q '^export JAVA_HOME=' "$CONF_DIR/hadoop-env.sh"; then
  sed -i "s|^export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|" "$CONF_DIR/hadoop-env.sh"
else
  printf '\nexport JAVA_HOME=%s\n' "$JAVA_HOME" >> "$CONF_DIR/hadoop-env.sh"
fi

mkdir -p "$DATA_HOME/namenode" "$DATA_HOME/datanode"
cat > "$CONF_DIR/core-site.xml" <<EOF2
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration>
  <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
</configuration>
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
<configuration>
  <property><name>mapreduce.framework.name</name><value>yarn</value></property>
</configuration>
EOF2
cat > "$CONF_DIR/yarn-site.xml" <<'EOF2'
<?xml version="1.0"?>
<!-- HADOOP_AUTO_MANAGED -->
<configuration>
  <property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property>
</configuration>
EOF2

# Add stable exports once; do not append duplicate PATH entries on every run.
for line in "export JAVA_HOME=$JAVA_HOME" "export HADOOP_HOME=$HADOOP_HOME" 'export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"'; do
  grep -qxF "$line" "$HOME/.bashrc" || printf '%s\n' "$line" >> "$HOME/.bashrc"
done
export JAVA_HOME HADOOP_HOME
export PATH="$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin"

log "Checking NameNode metadata before initialization..."
if [[ -f "$DATA_HOME/namenode/current/VERSION" ]]; then
  log "Existing NameNode metadata found. Preserving it; skipping format."
else
  if [[ -n "$(find "$DATA_HOME/namenode" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    die "NameNode directory is non-empty but has no recognizable VERSION metadata. For safety, not formatting it. Ask the lab administrator to inspect $DATA_HOME/namenode."
  fi
  log "No existing NameNode metadata found. Initializing the new NameNode once..."
  "$HADOOP_HOME/bin/hdfs" namenode -format -nonInteractive
fi

log "Starting HDFS and YARN (existing data will be preserved)..."
if ! pgrep -f 'org.apache.hadoop.hdfs.server.namenode.NameNode' >/dev/null; then "$HADOOP_HOME/sbin/start-dfs.sh"; fi
if ! pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null; then "$HADOOP_HOME/sbin/start-yarn.sh"; fi
sleep 5

log "Hadoop Java processes:"
jps || true
log "HDFS report:"
"$HADOOP_HOME/bin/hdfs" dfsadmin -report || true

cat <<EOF2

Hadoop ${HADOOP_VERSION} setup stage completed.
HADOOP_HOME=${HADOOP_HOME}
JAVA_HOME=${JAVA_HOME}
NameNode UI (Hadoop 2.7.0): http://localhost:50070
YARN UI: http://localhost:8088

Open a new terminal or run: source ~/.bashrc
To run the WordCount experiment, use the separate run-wordcount.sh script with your sample input file.
To stop services later: \"\$HADOOP_HOME/sbin/stop-yarn.sh\" then \"\$HADOOP_HOME/sbin/stop-dfs.sh\"
EOF2
