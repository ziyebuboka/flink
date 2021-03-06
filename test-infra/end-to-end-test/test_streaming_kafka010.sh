#!/usr/bin/env bash
################################################################################
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

set -e
set -o pipefail

# Convert relative path to absolute path
TEST_ROOT=`pwd`
TEST_INFRA_DIR="$0"
TEST_INFRA_DIR=`dirname "$TEST_INFRA_DIR"`
cd $TEST_INFRA_DIR
TEST_INFRA_DIR=`pwd`
cd $TEST_ROOT

. "$TEST_INFRA_DIR"/common.sh


start_cluster

# get Kafka 0.10.0
mkdir -p $TEST_DATA_DIR
if [ -z "$3" ]; then
  # need to download Kafka because no Kafka was specified on the invocation
  KAFKA_URL="http://mirror.netcologne.de/apache.org/kafka/0.10.2.0/kafka_2.11-0.10.2.0.tgz"
  echo "Downloading Kafka from $KAFKA_URL"
  curl "$KAFKA_URL" > $TEST_DATA_DIR/kafka.tgz
else
  echo "Using specified Kafka from $3"
  cp $3 $TEST_DATA_DIR/kafka.tgz
fi

tar xzf $TEST_DATA_DIR/kafka.tgz -C $TEST_DATA_DIR/
KAFKA_DIR=$TEST_DATA_DIR/kafka_2.11-0.10.2.0

# fix kafka config
sed -i -e "s+^\(dataDir\s*=\s*\).*$+\1$TEST_DATA_DIR/zookeeper+" $KAFKA_DIR/config/zookeeper.properties
sed -i -e "s+^\(log\.dirs\s*=\s*\).*$+\1$TEST_DATA_DIR/kafka+" $KAFKA_DIR/config/server.properties
$KAFKA_DIR/bin/zookeeper-server-start.sh -daemon $KAFKA_DIR/config/zookeeper.properties
$KAFKA_DIR/bin/kafka-server-start.sh -daemon $KAFKA_DIR/config/server.properties

# zookeeper outputs the "Node does not exist" bit to stderr
while [[ $($KAFKA_DIR/bin/zookeeper-shell.sh localhost:2181 get /brokers/ids/0 2>&1) =~ .*Node\ does\ not\ exist.* ]]; do
  echo "Waiting for broker..."
  sleep 1
done

# create the required topics
$KAFKA_DIR/bin/kafka-topics.sh --create --zookeeper localhost:2181 --replication-factor 1 --partitions 1 --topic test-input
$KAFKA_DIR/bin/kafka-topics.sh --create --zookeeper localhost:2181 --replication-factor 1 --partitions 1 --topic test-output

# run the Flink job (detached mode)
$FLINK_DIR/bin/flink run -d build-target/examples/streaming/Kafka010Example.jar \
  --input-topic test-input --output-topic test-output \
  --prefix=PREFIX \
  --bootstrap.servers localhost:9092 --zookeeper.connect localhost:2181 --group.id myconsumer --auto.offset.reset earliest

# send some data to Kafka
echo -e "hello\nwhats\nup" | $KAFKA_DIR/bin/kafka-console-producer.sh --broker-list localhost:9092 --topic test-input

# wait at most (roughly) 60 seconds until the results are there
for i in {1..60}; do
  DATA_FROM_KAFKA=$($KAFKA_DIR/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test-output --from-beginning --timeout-ms 0 2> /dev/null)

  # make sure we have actual newlines in the string, not "\n"
  EXPECTED=$(printf "PREFIX:hello\nPREFIX:whats\nPREFIX:up")

  if [[ "$DATA_FROM_KAFKA" == "$EXPECTED" ]]; then
    break
  fi

  echo "Waiting for results from Kafka..."
  sleep 1
done

# verify again to set the PASS variable
DATA_FROM_KAFKA=$($KAFKA_DIR/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic test-output --from-beginning --timeout-ms 0 2> /dev/null)

# make sure we have actual newlines in the string, not "\n"
EXPECTED=$(printf "PREFIX:hello\nPREFIX:whats\nPREFIX:up")
if [[ "$DATA_FROM_KAFKA" != "$EXPECTED" ]]; then
  echo "Output from Flink program does not match expected output."
  echo -e "EXPECTED: --$EXPECTED--"
  echo -e "ACTUAL: --$DATA_FROM_KAFKA--"
  PASS=""
fi

$KAFKA_DIR/bin/kafka-server-stop.sh
$KAFKA_DIR/bin/zookeeper-server-stop.sh

stop_cluster
clean_data_dir
check_all_pass
