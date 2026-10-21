#!/bin/bash
set -e
ARCH=$(dpkg --print-architecture)   # amd64 or arm64 (auto)
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-$ARCH
export HADOOP_HOME=/usr/local/hadoop
export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin
add_env() { grep -qxF "$1" ~/.bashrc || echo "$1" >> ~/.bashrc; }
# fetch <file> <url1> [url2...]: reuse a valid file in ~/Downloads, else resume-download (tries each URL)
fetch() {
  f=$1; shift
  if [ -f "$f" ] && tar -tzf "$f" >/dev/null 2>&1; then echo "Using existing $f"; return 0; fi
  for u in "$@"; do wget -c "$u" && return 0; done
  echo "Download failed. Put $f in ~/Downloads manually and rerun."; exit 1
}

echo "=== 1. Install Java, SSH, tools ==="
sudo apt update
sudo apt install -y curl wget git unzip build-essential nano openjdk-11-jdk openssh-server
java -version

echo "=== 2. Passwordless SSH ==="
sudo service ssh start
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
grep -qF "$(cat ~/.ssh/id_ed25519.pub)" ~/.ssh/authorized_keys 2>/dev/null || cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=no localhost exit

echo "=== 3. Environment variables ==="
add_env "export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-$ARCH"
add_env 'export HADOOP_HOME=/usr/local/hadoop'
add_env 'export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin'

echo "=== 4. Download and install Hadoop 3.3.6 ==="
if [ ! -d "$HADOOP_HOME" ]; then
  mkdir -p ~/Downloads && cd ~/Downloads
  fetch hadoop-3.3.6.tar.gz https://dlcdn.apache.org/hadoop/common/hadoop-3.3.6/hadoop-3.3.6.tar.gz https://archive.apache.org/dist/hadoop/common/hadoop-3.3.6/hadoop-3.3.6.tar.gz
  tar -xzf hadoop-3.3.6.tar.gz
  sudo mv hadoop-3.3.6 "$HADOOP_HOME"
  sudo chown -R "$USER":"$USER" "$HADOOP_HOME"
fi
hadoop version

echo "=== 5. Configure Hadoop ==="
grep -qF "JAVA_HOME=/usr/lib/jvm/java-11-openjdk-$ARCH" $HADOOP_HOME/etc/hadoop/hadoop-env.sh || \
  echo "export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-$ARCH" >> $HADOOP_HOME/etc/hadoop/hadoop-env.sh

cat > $HADOOP_HOME/etc/hadoop/core-site.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://localhost:9000</value>
  </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/hdfs-site.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>dfs.replication</name>
    <value>1</value>
  </property>
  <property>
    <name>dfs.namenode.name.dir</name>
    <value>file:/usr/local/hadoop/hadoop_data/hdfs/namenode</value>
  </property>
  <property>
    <name>dfs.datanode.data.dir</name>
    <value>file:/usr/local/hadoop/hadoop_data/hdfs/datanode</value>
  </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/mapred-site.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>mapreduce.framework.name</name>
    <value>yarn</value>
  </property>
  <property>
    <name>mapreduce.application.classpath</name>
    <value>$HADOOP_MAPRED_HOME/share/hadoop/mapreduce/*:$HADOOP_MAPRED_HOME/share/hadoop/mapreduce/lib/*</value>
  </property>
  <property>
    <name>yarn.app.mapreduce.am.env</name>
    <value>HADOOP_MAPRED_HOME=/usr/local/hadoop</value>
  </property>
  <property>
    <name>mapreduce.map.env</name>
    <value>HADOOP_MAPRED_HOME=/usr/local/hadoop</value>
  </property>
  <property>
    <name>mapreduce.reduce.env</name>
    <value>HADOOP_MAPRED_HOME=/usr/local/hadoop</value>
  </property>
</configuration>
EOF

cat > $HADOOP_HOME/etc/hadoop/yarn-site.xml <<'EOF'
<?xml version="1.0"?>
<configuration>
  <property>
    <name>yarn.nodemanager.aux-services</name>
    <value>mapreduce_shuffle</value>
  </property>
</configuration>
EOF

echo "=== 6. Format (first time only) and start Hadoop ==="
mkdir -p $HADOOP_HOME/hadoop_data/hdfs/namenode $HADOOP_HOME/hadoop_data/hdfs/datanode
[ -d $HADOOP_HOME/hadoop_data/hdfs/namenode/current ] || hdfs namenode -format
jps | grep -q NameNode || start-dfs.sh
jps | grep -q ResourceManager || start-yarn.sh
hdfs dfsadmin -safemode wait
jps
echo "HDFS UI: http://localhost:9870 | YARN UI: http://localhost:8088"

echo "=== 7. Input file and upload to HDFS ==="
mkdir -p ~/input
printf 'hello hadoop\nhello cloud computing\ncloud lab hadoop\n' > ~/input/file.txt
hdfs dfs -mkdir -p /input
hdfs dfs -put -f ~/input/file.txt /input/
hdfs dfs -ls /input

echo "=== 8. WordCount code ==="
mkdir -p ~/wordcount && cd ~/wordcount
cat > WordCount.java <<'EOF'
import java.io.IOException;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.Text;
import org.apache.hadoop.mapreduce.Job;
import org.apache.hadoop.mapreduce.Mapper;
import org.apache.hadoop.mapreduce.Reducer;
import org.apache.hadoop.mapreduce.lib.input.FileInputFormat;
import org.apache.hadoop.mapreduce.lib.output.FileOutputFormat;

public class WordCount {
    public static class TokenizerMapper extends Mapper<Object, Text, Text, IntWritable> {
        private final static IntWritable one = new IntWritable(1);
        private Text word = new Text();

        public void map(Object key, Text value, Context context) throws IOException, InterruptedException {
            String[] words = value.toString().trim().split("\\s+");
            for (String w : words) {
                if (w.isEmpty()) continue;
                word.set(w);
                context.write(word, one);
            }
        }
    }

    public static class IntSumReducer extends Reducer<Text, IntWritable, Text, IntWritable> {
        private IntWritable result = new IntWritable();

        public void reduce(Text key, Iterable<IntWritable> values, Context context)
                throws IOException, InterruptedException {
            int sum = 0;
            for (IntWritable val : values) {
                sum += val.get();
            }
            result.set(sum);
            context.write(key, result);
        }
    }

    public static void main(String[] args) throws Exception {
        Configuration conf = new Configuration();
        Job job = Job.getInstance(conf, "word count");
        job.setJarByClass(WordCount.class);
        job.setMapperClass(TokenizerMapper.class);
        job.setReducerClass(IntSumReducer.class);
        job.setOutputKeyClass(Text.class);
        job.setOutputValueClass(IntWritable.class);
        FileInputFormat.addInputPath(job, new Path(args[0]));
        FileOutputFormat.setOutputPath(job, new Path(args[1]));
        System.exit(job.waitForCompletion(true) ? 0 : 1);
    }
}
EOF

echo "=== 9. Compile, run, view output ==="
javac --release 11 -classpath $(hadoop classpath)  WordCount.java
jar cf wc.jar WordCount*.class
hdfs dfs -rm -r -f /output/wc
hadoop jar wc.jar WordCount /input/file.txt /output/wc
hdfs dfs -ls /output/wc
echo "----- OUTPUT -----"
hdfs dfs -cat /output/wc/part-r-00000
echo "DONE. Stop Hadoop with: stop-yarn.sh && stop-dfs.sh"
