#!/bin/bash
# Name: docker-elk-mssql-demo-setup.sh
# Owner: Saurav Mitra
# Description: Configure ELK Stack with MSSQL Server with Filebeat (for SQLAgent Log)
# Pre-requisite: Working Docker Installation/Docker Desktop
# 
# BUILD
# chmod +x docker-elk-mssql-demo-setup.sh
# ./docker-elk-mssql-demo-setup.sh
#
# CLEANUP
# cd mssql
# docker-compose down
# cd ../elk
# docker-compose down
# cd ..
# rm -rf mssql elk


# Environment Variables
# export work_dir="/Users/Saurav/Docker/MSSQL-ELASTIC-DEMO"
export work_dir=${PWD}
export db_password="P@ssw0rd1234"



# MSSQL Server
rm -rf ${work_dir}/mssql ${work_dir}/elk
mkdir ${work_dir}/mssql
cd ${work_dir}/mssql
tee ${work_dir}/mssql/docker-compose.yml &>/dev/null <<EOF
version: "3.1"
services:
  mssql:
    image: mcr.microsoft.com/mssql/server:2019-latest
    container_name: mssql
    ports:
      - 1433:1433
    environment:
      ACCEPT_EULA: Y
      SA_PASSWORD: ${db_password}
      MSSQL_PID: Developer
      MSSQL_AGENT_ENABLED: "true"
EOF

docker-compose up -d



# ELK Stack
mkdir ${work_dir}/elk
mkdir ${work_dir}/elk/logstash
mkdir ${work_dir}/elk/logstash/config
mkdir ${work_dir}/elk/logstash/pipeline

# Logstash

tee ${work_dir}/elk/logstash/config/logstash.yml &>/dev/null <<EOF
http.host: "0.0.0.0"
EOF

tee ${work_dir}/elk/logstash/pipeline/logstash.conf &>/dev/null <<EOF
input {
  beats {
    port => 5044
    codec => plain { 
      charset => "UTF-8"
    }
    include_codec_tag => false
  }
}
filter {
  grok {
    match => { "message" => "%{TIMESTAMP_ISO8601:log_timestamp} - %{NOTSPACE:log_severity} %{GREEDYDATA:log_message}" }
  }
  date {
    match => [ "log_timestamp" , "yyyy-MM-dd HH:mm:ss" ]
  }
  translate {
    field => "log_severity"
    destination => "severity"
    dictionary => {
      "?" => "Info"
      "+" => "Warning"
      "!" => "Error"
    }
    remove_field => "log_severity"
  }
  mutate
  {
    remove_field => [ "message" ]
  }
}
output {
  elasticsearch {
    hosts => "host.docker.internal:9200"
    user => "elastic"
    password => "${db_password}"
    index => "%{[@metadata][beat]}-%{+yyyy-MM-dd}"
  }
  stdout {}
}
EOF


# ELK
tee ${work_dir}/elk/docker-compose.yml &>/dev/null <<EOF
version: '3.5'
volumes:
  elasticsearch-data:
networks:
  elk: {}
services:
  elasticsearch:
    image: elasticsearch:7.14.2
    ports:
      - 9200:9200
    environment:
      - bootstrap.memory_lock=true
      - discovery.type=single-node
      - xpack.security.enabled=true
      - ES_JAVA_OPTS= -Xmx2g -Xms2g
      - ELASTIC_PASSWORD=${db_password}
    ulimits:
      memlock:
        soft: -1
        hard: -1
    networks:
      - elk

  logstash:
    image: logstash:7.14.2
    ports:
      - 5044:5044
    volumes:
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml:ro
      - ./logstash/pipeline/logstash.conf:/usr/share/logstash/pipeline/logstash.conf:ro
    environment:
      - LS_JAVA_OPTS=-Xmx1g -Xms1g
    depends_on:
      - elasticsearch
    networks:
      - elk

  kibana:
    image: kibana:7.14.2
    ports:
      - 5601:5601
    environment:
      - ELASTICSEARCH_USERNAME=elastic
      - ELASTICSEARCH_PASSWORD=${db_password}
    depends_on:
      - elasticsearch
    networks:
      - elk

EOF

cd ${work_dir}/elk
docker-compose up -d


# Setup Filebeat in MSSQL Container
echo "Setting up Filebeat on MSSQL Container"
cd ${work_dir}/mssql
tee ${work_dir}/mssql/install_filebeat.sh &>/dev/null <<EOF
apt-get update
apt-get -y install curl vim
curl -L -O https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-7.14.2-amd64.deb
dpkg -i filebeat-7.14.2-amd64.deb
mv /etc/filebeat/filebeat.yml /etc/filebeat/filebeat.yml.bkp

echo "filebeat.inputs:" > /etc/filebeat/filebeat.yml
echo "- type: log" >> /etc/filebeat/filebeat.yml
echo "  enabled: true" >> /etc/filebeat/filebeat.yml
echo "  paths:" >> /etc/filebeat/filebeat.yml
echo "    - /var/opt/mssql/log/sqlagent.out" >> /etc/filebeat/filebeat.yml
echo "  encoding: utf-16le-bom" >> /etc/filebeat/filebeat.yml
echo "filebeat.config.modules:" >> /etc/filebeat/filebeat.yml
echo '  path: \${path.config}/modules.d/*.yml' >> /etc/filebeat/filebeat.yml
echo "  reload.enabled: false" >> /etc/filebeat/filebeat.yml
echo "  setup.template.settings:" >> /etc/filebeat/filebeat.yml
echo "    index.number_of_shards: 1" >> /etc/filebeat/filebeat.yml

echo "# output.elasticsearch:" >> /etc/filebeat/filebeat.yml
echo '#   hosts: ["host.docker.internal:9200"]' >> /etc/filebeat/filebeat.yml
echo "#   username: elastic" >> /etc/filebeat/filebeat.yml
echo "#   password: P@ssw0rd1234" >> /etc/filebeat/filebeat.yml
echo "setup.kibana:" >> /etc/filebeat/filebeat.yml
echo '  host: "host.docker.internal:5601"' >> /etc/filebeat/filebeat.yml
echo "output.logstash:" >> /etc/filebeat/filebeat.yml
echo '  hosts: ["host.docker.internal:5044"]' >> /etc/filebeat/filebeat.yml


# filebeat setup
# filebeat setup --index-management -E output.logstash.enabled=false -E 'output.elasticsearch.hosts=["host.docker.internal:9200"]'  -E 'output.elasticsearch.username=elastic' -E 'output.elasticsearch.password=P@ssw0rd1234'
service filebeat start

EOF

docker exec -u 0 -i mssql bash < ${work_dir}/mssql/install_filebeat.sh
