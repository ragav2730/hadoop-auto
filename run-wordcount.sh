#!/usr/bin/env bash
set -Eeuo pipefail

HADOOP_HOME="${HADOOP_HOME:-$HOME/hadoop-2.7.0}"
INPUT_FILE="${1:-}"
HDFS_INPUT_DIR="/user1"
HDFS_OUTPUT_GREP="/output-grep"
HDFS_OUTPUT_WORDCOUNT="/output1"

if [[ -z "$INPUT_FILE" ]]; then
  echo "Usage: $0 /path/to/file1.txt" >&2
  echo "Provide the file1.txt extracted from your lab's mrsampledata.tar.gz." >&2
  exit 2
fi
[[ -f "$INPUT_FILE" ]] || { echo "Input file not found: $INPUT_FILE" >&2; exit 2; }
[[ -x "$HADOOP_HOME/bin/hdfs" ]] || { echo "Hadoop not found at $HADOOP_HOME. Run install.sh first." >&2; exit 2; }

if ! pgrep -f 'org.apache.hadoop.hdfs.server.namenode.NameNode' >/dev/null; then
  "$HADOOP_HOME/sbin/start-dfs.sh"
fi
if ! pgrep -f 'org.apache.hadoop.yarn.server.resourcemanager.ResourceManager' >/dev/null; then
  "$HADOOP_HOME/sbin/start-yarn.sh"
fi

"$HADOOP_HOME/bin/hdfs" dfs -mkdir -p "$HDFS_INPUT_DIR"
"$HADOOP_HOME/bin/hdfs" dfs -put -f "$INPUT_FILE" "$HDFS_INPUT_DIR/"

# Hadoop refuses to write into an existing output directory; remove only these
# experiment output paths, never the user's input directory or other HDFS data.
"$HADOOP_HOME/bin/hdfs" dfs -rm -r -f "$HDFS_OUTPUT_GREP" "$HDFS_OUTPUT_WORDCOUNT" >/dev/null 2>&1 || true
EXAMPLES_JAR="$HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-2.7.0.jar"
[[ -f "$EXAMPLES_JAR" ]] || { echo "Missing MapReduce examples JAR: $EXAMPLES_JAR" >&2; exit 1; }

"$HADOOP_HOME/bin/hadoop" jar "$EXAMPLES_JAR" grep "$HDFS_INPUT_DIR/*" "$HDFS_OUTPUT_GREP" '(CSE)'
"$HADOOP_HOME/bin/hadoop" jar "$EXAMPLES_JAR" wordcount "$HDFS_INPUT_DIR/$(basename "$INPUT_FILE")" "$HDFS_OUTPUT_WORDCOUNT"

echo "\nGREP output:"
"$HADOOP_HOME/bin/hdfs" dfs -cat "$HDFS_OUTPUT_GREP"/* || true
echo "\nWORDCOUNT output:"
"$HADOOP_HOME/bin/hdfs" dfs -cat "$HDFS_OUTPUT_WORDCOUNT"/*
echo "\nExperiment 2 completed."
