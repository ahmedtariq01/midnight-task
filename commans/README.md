# Setup commands

This reference follows the order used to bring up the AWS PreProd lab. It includes the main setup commands and repeatable verification checks. Use the [runbook](../RUNBOOK.md) for configuration and expected outputs. Commands labelled **Workstation** run from the repository root. Commands labelled **EC2** run in the authorized Session Manager shell.

## 1. Provision the AWS host

**Workstation.** Initialize and review the [live EC2 Terraform root](../infra/ec2/README.md). The Ohio plan was applied after review.

```bash
terraform -chdir=infra/ec2 init
terraform -chdir=infra/ec2 fmt -check
terraform -chdir=infra/ec2 validate
terraform -chdir=infra/ec2 plan -out=ohio.tfplan
terraform -chdir=infra/ec2 show -no-color ohio.tfplan
```

Apply the reviewed plan and record the actual instance and volume IDs for the storage bootstrap.

```bash
terraform -chdir=infra/ec2 apply ohio.tfplan
terraform -chdir=infra/ec2 output -raw instance_id
terraform -chdir=infra/ec2 output -raw data_volume_id
terraform -chdir=infra/ec2 plan
```

Open **EC2 → Instances → Connect → Session Manager → Connect** in the Ohio region. The shell was opened through the AWS console. [Deployment and Terraform review](../infra/ec2/README.md#deployment-and-terraform-review)

## 2. Prepare EBS, PostgreSQL, and Cardano

**EC2.** Stage the reviewed [bootstrap scripts](../infra/ec2/bootstrap/) in the session. Substitute the Terraform output IDs below. The storage stage can format a blank device. Review the [storage procedure](../RUNBOOK.md#prepare-persistent-data-storage) and verify the mapped 500 GiB device before running it.

```bash
EC2_INSTANCE_ID='<instance_id Terraform output>'
EBS_VOLUME_ID='<data_volume_id Terraform output>'
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,SERIAL
sudo bash storage-postgres.sh storage "$EC2_INSTANCE_ID" "$EBS_VOLUME_ID"
findmnt /srv/midnight
```

Once the mount is present, PostgreSQL setup and relay setup can run in separate sessions. The relay script verifies the Mithril snapshot before restoring certified blocks and starting the pinned Cardano binary. Start DB Sync after both prerequisites are active. [Cardano bootstrap](../RUNBOOK.md#start-the-cardano-services)

```bash
sudo bash storage-postgres.sh postgres "$EC2_INSTANCE_ID" "$EBS_VOLUME_ID"
sudo bash cardano-relay.sh
sudo bash db-sync.sh
systemctl is-active cardano-node.service postgresql@17-main.service cardano-db-sync.service
sudo journalctl -u cardano-node -u cardano-db-sync --since '10 minutes ago' --no-pager
```

Repeat the SQL and relay queries to verify advancing PostgreSQL height, then compare the block number and hash against the live relay before starting Midnight. [Cardano evidence](../RUNBOOK.md#live-preprod-evidence)

```bash
sudo -u postgres psql -XAt -d cexplorer -c "
  SELECT clock_timestamp() AT TIME ZONE 'UTC', block_no, slot_no, encode(hash, 'hex')
  FROM public.block
  WHERE block_no IS NOT NULL
  ORDER BY id DESC
  LIMIT 1;"

sudo -u cardano /opt/cardano-node/11.0.1/bin/cardano-cli query tip \
  --socket-path /run/cardano-node/node.socket --testnet-magic 1
```

## 3. Prepare the PostgreSQL TLS reader and start Midnight

**EC2.** Configure the loopback TLS endpoint and dedicated read-only reader as described in the [PostgreSQL runbook](../RUNBOOK.md#prepare-midnights-postgresql-connection). Validate the configuration files before reloading PostgreSQL. After the reader connects, check the reported TLS version from a local admin session.

```bash
sudo -u postgres psql -X -d cexplorer -c \
  "SELECT name, error FROM pg_file_settings WHERE error IS NOT NULL"
sudo -u postgres psql -X -d cexplorer -c \
  "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL"
sudo -u postgres psql -X -d cexplorer -c 'SELECT pg_reload_conf()'
sudo -u postgres psql -X -d cexplorer -c "
  SELECT a.usename, s.ssl, s.version
  FROM pg_stat_ssl AS s
  JOIN pg_stat_activity AS a USING (pid)
  WHERE a.usename = 'midnight_reader';"
```

Create the three required Midnight indexes as the database owner before starting the service. Run each statement separately with autocommit in a local `psql` session as `postgres`.

```sql
SET ROLE dbsync;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ma_tx_out_ident ON public.ma_tx_out (ident);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_out_address ON public.tx_out USING hash (address);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ma_tx_out_id_ident ON public.ma_tx_out (tx_out_id, ident);
```

Verify the release checksum and configure the archive's systemd unit with the [pinned startup command](../RUNBOOK.md#start-the-midnight-preprod-archive-node), then start it.

```bash
printf '%s  %s\n' \
  48ce9d44464117b4ee8c1194209ebbbc4ea7d1adc39a77edeef1d1aa2b3ffbb5 \
  midnight-node-2.1.101-linux-amd64.tar.gz | sha256sum --check
sudo systemctl daemon-reload
sudo systemctl enable --now midnight-node.service
sudo journalctl -u midnight-node.service --since '10 minutes ago' --no-pager
```

## 4. Start and verify the indexer

**EC2.** Define a helper for the local archive RPC. Check health, sync state, and finalized head. Before starting the indexer, verify PreProd genesis and historical block bodies and runtime state. [Indexer prerequisites and pinned container command](../RUNBOOK.md#start-the-standalone-midnight-indexer)

```bash
midnight_rpc() {
  local method=$1 params=${2:-[]}
  curl -fsS --max-time 8 -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg method "$method" --argjson params "$params" \
      '{jsonrpc:"2.0",id:1,method:$method,params:$params}')" \
    http://127.0.0.1:9944
}

date -u +%FT%TZ
midnight_rpc system_health
midnight_rpc system_syncState
FINALIZED_HASH=$(midnight_rpc chain_getFinalizedHead | jq -er '.result')
midnight_rpc chain_getHeader "[\"$FINALIZED_HASH\"]"
midnight_rpc chain_getBlockHash '[0]'
HISTORICAL_HASH=$(midnight_rpc chain_getBlockHash '[1000]' | jq -er '.result')
midnight_rpc chain_getBlock "[\"$HISTORICAL_HASH\"]" | jq -e '.result.block.header'
midnight_rpc state_getRuntimeVersion "[\"$HISTORICAL_HASH\"]" | jq -e '.result.specVersion'
```

Create the pinned container and its service using the runbook. Start the unit and compare the indexer GraphQL hash with the archive hash at the same height. Check each HTTP endpoint separately. [Timestamped verification and public hashes](../RUNBOOK.md#repeat-replay-and-public-hash-check)

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now midnight-indexer.service
systemctl is-active midnight-node.service midnight-indexer.service

for endpoint in live ready; do
  curl -sS --max-time 8 -o /dev/null -w "$endpoint %{http_code}\n" \
    "http://127.0.0.1:8088/$endpoint"
done

INDEXER_BLOCK=$(curl -fsS --max-time 8 -H 'Content-Type: application/json' \
  --data '{"query":"{ block { height hash } }"}' \
  http://127.0.0.1:8088/api/v4/graphql)
INDEXED_HEIGHT=$(jq -er '.data.block.height | tonumber' <<<"$INDEXER_BLOCK")
INDEXED_HASH=$(jq -er '.data.block.hash' <<<"$INDEXER_BLOCK")
ARCHIVE_HASH=$(midnight_rpc chain_getBlockHash "[$INDEXED_HEIGHT]" | jq -er '.result')
printf 'Height %s\nIndexer %s\nArchive %s\n' "$INDEXED_HEIGHT" "$INDEXED_HASH" "$ARCHIVE_HASH"
test "${INDEXED_HASH#0x}" = "${ARCHIVE_HASH#0x}"
```

## 5. Start and verify monitoring

**EC2.** The following equivalent startup examples use the lab's pinned images and bind addresses. Run the container creation commands on a fresh deployment after staging the referenced configuration. For an existing deployment, use the verification commands below.

### Node Exporter and replay probes

Install the Ubuntu Node Exporter package. Configure its systemd drop-in with the loopback listener and replay textfile directory used in the lab.

```bash
sudo apt-get install -y prometheus-node-exporter
sudo install -d -m 0755 /var/lib/midnight-ops/metrics
sudo install -d -m 0755 /etc/systemd/system/prometheus-node-exporter.service.d
sudo tee /etc/systemd/system/prometheus-node-exporter.service.d/midnight.conf >/dev/null <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/midnight-ops/metrics
UNIT
sudo systemctl daemon-reload
sudo systemctl restart prometheus-node-exporter.service
```

The lab runs the [replay probe script](../monitoring/probes/replay_metrics.py) in a root-owned one-shot service so it can query both the Cardano socket and PostgreSQL. Use a 30-second systemd timer and the textfile directory above. Check both units once the timer has been installed. [Host metrics and replay probes](../monitoring/README.md)

```bash
sudo systemctl enable --now midnight-replay-metrics.timer
sudo systemctl start midnight-replay-metrics.service
systemctl is-active prometheus-node-exporter.service midnight-replay-metrics.timer
curl -fsS --max-time 5 http://127.0.0.1:9100/metrics |
  grep '^midnight_ops_probe_success'
```

### Prometheus

Stage [`prometheus.yml`](../monitoring/prometheus.yml) and [`alerts.yml`](../monitoring/alerts.yml) in one host directory. Make `/srv/midnight/prometheus` writable by the container user before starting the pinned image.

```bash
PROMETHEUS_CONFIG_DIR='<absolute directory with the two reviewed YAML files>'
sudo docker run -d --name midnight-prometheus --network host --restart unless-stopped \
  --mount "type=bind,src=$PROMETHEUS_CONFIG_DIR,dst=/etc/prometheus,readonly" \
  --mount type=bind,src=/srv/midnight/prometheus,dst=/prometheus \
  prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06 \
  --config.file=/etc/prometheus/prometheus.yml --web.listen-address=127.0.0.1:9090 \
  --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=3d \
  --storage.tsdb.retention.size=1GB
```

### Grafana and Nginx

Stage the [provisioning and dashboards](../monitoring/grafana/README.md) under `/etc/midnight/grafana`. Populate the AWS dashboard's EC2 and EBS variables from Terraform outputs. Provision the CloudWatch data source when the EC2 role has its scoped read policy. The protected bootstrap password file must be readable by UID 472. Use your approved file and mount paths in the placeholders.

```bash
GRAFANA_PUBLIC_IP='<operator-accessible EC2 IPv4 address>'
GRAFANA_PASSWORD_FILE='<absolute path to the protected host file>'
GRAFANA_PASSWORD_MOUNT='<absolute mount path in the container>'
sudo install -d -o 472 -g 472 -m 0750 /srv/midnight/grafana
sudo docker run -d --name midnight-grafana --network host --user 472:472 \
  --restart unless-stopped --cap-drop ALL --security-opt no-new-privileges \
  --mount type=bind,src=/srv/midnight/grafana,dst=/var/lib/grafana \
  --mount type=bind,src=/etc/midnight/grafana/provisioning,dst=/etc/grafana/provisioning,readonly \
  --mount type=bind,src=/etc/midnight/grafana/dashboards,dst=/var/lib/grafana/dashboards,readonly \
  --mount "type=bind,src=$GRAFANA_PASSWORD_FILE,dst=$GRAFANA_PASSWORD_MOUNT,readonly" \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 -e "GF_SERVER_DOMAIN=$GRAFANA_PUBLIC_IP" \
  -e "GF_SERVER_ROOT_URL=https://$GRAFANA_PUBLIC_IP/" \
  -e GF_SECURITY_ADMIN_USER=admin -e "GF_SECURITY_ADMIN_PASSWORD__FILE=$GRAFANA_PASSWORD_MOUNT" \
  -e GF_SECURITY_COOKIE_SECURE=true -e GF_AUTH_ANONYMOUS_ENABLED=false -e GF_USERS_ALLOW_SIGN_UP=false \
  grafana/grafana:13.3.1@sha256:0615ec4fbd4072004b7d86b46ded63013a74b7d6eb1119273dd89e8fa25c13cf
```

After staging the Nginx configuration and issuing the IP certificate, validate the proxy, renewal hook, and local monitoring endpoints.

```bash
sudo nginx -t
sudo certbot renew --cert-name "$GRAFANA_PUBLIC_IP" --dry-run --run-deploy-hooks --non-interactive
curl -fsSG --max-time 5 --data-urlencode 'query=up{job=~"midnight-node|node"}' \
  http://127.0.0.1:9090/api/v1/query
curl -fsS --max-time 5 http://127.0.0.1:9090/api/v1/alerts
curl -fsS --max-time 5 http://127.0.0.1:3000/api/health
```

### CloudWatch Agent

After installing the AWS agent, creating the seven-day log group and attaching the scoped instance policy, stage the [reviewed journal filters](../monitoring/cloudwatch/agent.json) on EC2 and load them. The live host also runs a separate journal follower for the indexer container.

```bash
CLOUDWATCH_AGENT_CONFIG='<absolute path to the staged agent.json>'
sudo install -m 0644 "$CLOUDWATCH_AGENT_CONFIG" /etc/midnight/cloudwatch-logs.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/etc/midnight/cloudwatch-logs.json -s
systemctl is-active amazon-cloudwatch-agent.service midnight-indexer-log-follow.service
```

**Workstation.** Use authorized AWS access to inspect the regional CPU metric and the service log streams. Fetch live sample values in the provisioned AWS dashboard and inspect recent events in the Service Logs dashboard. [CloudWatch configuration and verification](../monitoring/grafana/README.md#cloudwatch)

```bash
EC2_INSTANCE_ID=$(terraform -chdir=infra/ec2 output -raw instance_id)
aws cloudwatch list-metrics --region us-east-2 --namespace AWS/EC2 \
  --metric-name CPUUtilization --dimensions "Name=InstanceId,Value=$EC2_INSTANCE_ID"
aws logs describe-log-streams --region us-east-2 --log-group-name /midnight/preprod/host \
  --query 'logStreams[].logStreamName'
```

## 6. Reproduce the local and CI checks

**Workstation.** Run the health checker and Prometheus unit tests, then validate and test the reusable Terraform outline. The mock Terraform plan uses the PreProd example inputs. [Tools and CI setup](../infra/README.md#local-verification)

```bash
python3 -m unittest discover -s scripts -p 'test_*.py' -v
promtool check config monitoring/prometheus.yml
promtool test rules monitoring/alerts.test.yml
terraform -chdir=infra/stack fmt -check -recursive
terraform -chdir=infra/stack init -backend=false -input=false -lockfile=readonly
terraform -chdir=infra/stack validate
tflint --chdir=infra/stack --recursive
checkov --directory infra/stack --framework terraform \
  --check CKV_AWS_3,CKV_AWS_8,CKV_AWS_24,CKV_AWS_25,CKV_AWS_79 --compact
terraform -chdir=infra/stack test -no-color -verbose \
  -var-file=environments/preprod.tfvars.example
```
