#!/bin/bash

set -e

echo "===== Hadoop Auto Installer ====="


###################################
# Root permission
###################################

sudo -v


###################################
# Update
###################################

sudo apt update -y


###################################
# Java
###################################

if ! command -v java >/dev/null
then

sudo apt install openjdk-8-jdk -y

fi


JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))

echo "JAVA_HOME=$JAVA_HOME"



###################################
# SSH
###################################

sudo apt install openssh-server -y

sudo systemctl enable ssh

sudo systemctl start ssh



###################################
# SSH keys
###################################

mkdir -p ~/.ssh

if [ ! -f ~/.ssh/id_rsa ]
then

ssh-keygen \
-q \
-t rsa \
-N "" \
-f ~/.ssh/id_rsa

fi


cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

chmod 600 ~/.ssh/authorized_keys


ssh-keyscan \
localhost \
>> ~/.ssh/known_hosts



###################################
# Download Hadoop
###################################

cd ~

if [ ! -d hadoop-2.7.0 ]
then

wget \
https://archive.apache.org/dist/hadoop/common/hadoop-2.7.0/hadoop-2.7.0.tar.gz


tar -xzf \
hadoop-2.7.0.tar.gz

fi



HADOOP_HOME=~/hadoop-2.7.0


###################################
# bashrc
###################################

grep -qxF \
"export JAVA_HOME=$JAVA_HOME" \
~/.bashrc \
|| echo \
"export JAVA_HOME=$JAVA_HOME" \
>> ~/.bashrc


grep -qxF \
"export HADOOP_HOME=$HADOOP_HOME" \
~/.bashrc \
|| echo \
"export HADOOP_HOME=$HADOOP_HOME" \
>> ~/.bashrc



echo \
'export PATH=$PATH:$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HOME/sbin' \
>> ~/.bashrc


source ~/.bashrc



###################################
# hadoop-env
###################################

sed -i \
"s|export JAVA_HOME=.*|export JAVA_HOME=$JAVA_HOME|" \
$HADOOP_HOME/etc/hadoop/hadoop-env.sh



###################################
# core-site.xml
###################################

cat > \
$HADOOP_HOME/etc/hadoop/core-site.xml <<EOF

<configuration>

<property>

<name>fs.defaultFS</name>

<value>hdfs://localhost:9000</value>

</property>

</configuration>

EOF



###################################
# hdfs
###################################

mkdir -p ~/hadoopdata/hdfs/namenode

mkdir -p ~/hadoopdata/hdfs/datanode



cat > \
$HADOOP_HOME/etc/hadoop/hdfs-site.xml <<EOF

<configuration>

<property>

<name>dfs.replication</name>

<value>1</value>

</property>


<property>

<name>dfs.namenode.name.dir</name>

<value>file:///home/$USER/hadoopdata/hdfs/namenode</value>

</property>


<property>

<name>dfs.datanode.data.dir</name>

<value>file:///home/$USER/hadoopdata/hdfs/datanode</value>

</property>

</configuration>

EOF



###################################
# mapred
###################################

cp \
$HADOOP_HOME/etc/hadoop/mapred-site.xml.template \
$HADOOP_HOME/etc/hadoop/mapred-site.xml



cat > \
$HADOOP_HOME/etc/hadoop/mapred-site.xml <<EOF

<configuration>

<property>

<name>mapreduce.framework.name</name>

<value>yarn</value>

</property>

</configuration>

EOF



###################################
# yarn
###################################

cat > \
$HADOOP_HOME/etc/hadoop/yarn-site.xml <<EOF

<configuration>

<property>

<name>yarn.nodemanager.aux-services</name>

<value>mapreduce_shuffle</value>

</property>

</configuration>

EOF



###################################
# Clean old
###################################

pkill -f NameNode || true

pkill -f DataNode || true

pkill -f ResourceManager || true

pkill -f NodeManager || true



###################################
# Format
###################################

$HADOOP_HOME/bin/hdfs \
namenode \
-format \
-force



###################################
# Start
###################################

$HADOOP_HOME/sbin/start-dfs.sh

$HADOOP_HOME/sbin/start-yarn.sh



sleep 10



###################################
# Verify
###################################

echo ""

echo "Processes:"

jps



echo ""

echo "Open browser:"


xdg-open \
http://localhost:50070 \
>/dev/null 2>&1 \
|| true



echo ""

echo "DONE"
