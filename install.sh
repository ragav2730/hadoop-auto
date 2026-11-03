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
