# Midnight PreProd bring-up

## AWS host and access

Use the [EC2 Terraform configuration](infra/ec2/README.md) for the Ubuntu 24.04 x86-64 host and its separate 500 GiB EBS volume. Open the host through **EC2 → Connect → In web browser → SSM Session Manager**. Grafana's ingress is limited to the operator HTTPS rule and the ACME challenge endpoint.

## Prepare persistent data storage

Bring the [bootstrap scripts](infra/ec2/bootstrap/) into the guest through the approved Session Manager session. Run the storage stage with the EC2 instance ID and EBS volume ID from the Terraform outputs. The storage stage checks the instance identity, matches the volume by NVMe serial and byte size, verifies signatures and mount state, and formats a blank disk once. It writes a UUID mount in `/etc/fstab` and creates the service accounts and data directories on the mounted filesystem.

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,SERIAL
sudo bash storage-postgres.sh storage "$EC2_INSTANCE_ID" "$EBS_VOLUME_ID"
findmnt /srv/midnight
```

## Start the Cardano services

Run the PostgreSQL and relay stages in separate Session Manager shells or transient systemd jobs. They can run concurrently once the mount is ready.

```bash
sudo bash storage-postgres.sh postgres "$EC2_INSTANCE_ID" "$EBS_VOLUME_ID"
sudo bash cardano-relay.sh
```

- PostgreSQL 17 uses its signed PGDG packages and a cluster at `/srv/midnight/postgresql/17/main`. It listens on loopback and the local Unix socket. The `cexplorer` database is owned by the dedicated `dbsync` database role. Its generated local authentication file is `/etc/midnight/dbsync.pgpass` with mode `0600`.
- Cardano node and CLI `11.0.1` use the release's PreProd configuration and network magic `1`. The bootstrap verifies the Mithril snapshot certificate chain and immutable chain files. It restores the certified blocks and lets the pinned Cardano release rebuild its ledger locally. Relay data goes to `/srv/midnight/cardano/db`, and the socket is `/run/cardano-node/node.socket`. The relay binds to `0.0.0.0:3001` inside the guest. The EC2 security group blocks inbound access to port `3001`.

After PostgreSQL accepts the local DB Sync connection and the relay starts, run the DB Sync stage.

```bash
sudo bash db-sync.sh
systemctl is-active cardano-node.service postgresql@17-main.service cardano-db-sync.service
systemctl is-enabled cardano-node.service postgresql.service cardano-db-sync.service
```

The Cardano DB Sync `13.7.1.0` service reads the relay's socket and writes PostgreSQL rows plus ledger state under `/srv/midnight/db-sync/state`. Its packaged schema is applied on first start. Systemd mount dependencies prevent services from writing state to the root filesystem if the data volume is unavailable.

## Verify indexing

Run the SQL check twice and record the UTC observation time, block number, and slot number. The database should show consecutive observations with an increasing indexed height. These observations establish indexing progress. For the later Midnight startup, compare the database height and block time with the live PreProd relay tip and verify they track it.

```bash
sudo -u postgres psql -XAt -d cexplorer -c "
  SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS') || ' UTC',
         block_no, slot_no, time
  FROM public.block
  WHERE block_no IS NOT NULL
  ORDER BY id DESC
  LIMIT 1;"

sudo -u cardano /opt/cardano-node/11.0.1/bin/cardano-cli query tip \
  --socket-path /run/cardano-node/node.socket --testnet-magic 1
```

Use `sudo journalctl -u cardano-node -u cardano-db-sync --since '10 minutes ago' --no-pager` to distinguish relay replay, schema initialization, and a restart loop. Keep the EC2 host running while the services catch up.

## Bootstrap observations

- The Mithril snapshot producer used a newer Cardano release. The restore used certified immutable blocks and the pinned relay replayed its local ledger before opening the Unix socket.
- Binding the relay to loopback produced outbound peer connection errors. The runbook uses the documented IPv4 wildcard binding with the lab's ingress closed at the security group. Changing the bind required a restart, and the relay replayed the ledger again because its ledger snapshot directory was empty.
- To check the network path separately from Cardano's peer state, run `timeout 8 bash -c 'exec 3<>/dev/tcp/preprod-node.play.dev.cardano.org/3001'`. An established Cardano peer and an advancing live relay tip provide the relay-level check.

## Live PreProd evidence

On 16 November 2026 the data volume was formatted as ext4 and mounted at `/srv/midnight` by filesystem UUID. PostgreSQL reported version `17.12`, data directory `/srv/midnight/postgresql/17/main`, and TCP listen address `127.0.0.1`.

The relay bootstrapped from verified Mithril snapshot digest `edab42a1e9ad419fcc37d27c43d55387d4bf55a7b0f1fc36eb24abe7fb949c9c`. After the relay bind correction and restart, these two readings came from the newest indexed row in PostgreSQL `cexplorer.public.block`.

| Observation time (UTC) | Indexed block height | Indexed slot | Indexed block time (UTC) |
|---|---:|---:|---|
| 2026-11-16 17:21:17 | 180,603 | 10,731,434 | 2022-10-22 04:57:14 |
| 2026-11-16 17:21:47 | 205,336 | 11,236,113 | 2022-10-28 01:08:33 |

The indexed height advanced by 24,733 blocks in 30 seconds. At handoff the Cardano relay reported `100.00` sync progress at block 5,419,979, with 27 established peer connections. The relay, PostgreSQL, and DB Sync were active under systemd and continued replaying the historical backlog.

After the nine near-tip migrations completed, PostgreSQL matched the live Cardano relay at both readings.

| Observation time (UTC) | Relay and PostgreSQL height | Slot | Matching block hash |
|---|---:|---:|---|
| 2026-11-16 22:35:43 | 5,420,843 | 139,185,333 | `0ded87ec3deb9ef7340fee3f9923c7bfd9d2fb14e292f94490c4ef56e1658c8f` |
| 2026-11-16 22:36:43 | 5,420,848 | 139,185,392 | `aacf622be6aa0351ea763f9ef750246fe08fba4a2092749d02fe17d41fae2716` |

[AWS EBS volume mapping](https://docs.aws.amazon.com/ebs/latest/userguide/identify-nvme-ebs-device.html) · [Midnight relay setup](https://docs.midnight.network/nodes/cardano-node) · [Midnight DB Sync setup](https://docs.midnight.network/nodes/cardano-db-sync) · [Mithril bootstrap](https://mithril.network/doc/manual/getting-started/bootstrap-cardano-node/)

## Prepare Midnight's PostgreSQL connection

Verify Cardano DB Sync is tracking the live Cardano relay before starting Midnight. Create a dedicated `midnight_reader` login with `CONNECT` to `cexplorer`, `USAGE` on `public`, and `SELECT` on its tables. Set its default transaction mode to read-only. Generate the password on the host and keep the DSN in `/etc/midnight/midnight-node.env`, owned by root with mode `0600`.

Issue a local PostgreSQL server certificate with an IP subject alternative name for `127.0.0.1`. Place its private key in the PostgreSQL configuration directory, owned by `postgres` with mode `0600`, and install the public CA certificate at `/etc/midnight/postgres-ca.crt`. Add a TLS configuration drop-in and the `hostssl cexplorer midnight_reader 127.0.0.1/32 scram-sha-256` HBA entry. Preserve the existing `dbsync` rule. The PostgreSQL bootstrap regenerates the HBA file, so restore the reader entry before reloading if the bootstrap is run again.

Check `pg_file_settings` and `pg_hba_file_rules` for errors, then run `SELECT pg_reload_conf()` as the database administrator. Test the reader with `PGSSLMODE=verify-full`, `PGSSLROOTCERT=/etc/midnight/postgres-ca.crt`, and a temporary protected password file. Confirm the reader can select the Cardano tip over TLS and lacks write access. On this host, the reader connected with TLS 1.3 and PostgreSQL and DB Sync retained their original processes through the reload.

The `2.1.101` candidate data source checks for three named indexes during startup. Its first startup failed when the read-only service tried to create the missing indexes. From a `psql -X -d cexplorer` session as `postgres`, run each statement separately with autocommit. `SET ROLE` limits the index changes to the existing table owner.

```sql
SET ROLE dbsync;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ma_tx_out_ident ON public.ma_tx_out (ident);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_out_address ON public.tx_out USING hash (address);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ma_tx_out_id_ident ON public.ma_tx_out (tx_out_id, ident);
```

Check `pg_stat_progress_create_index` while they build. Before starting Midnight, check `pg_index.indisready` and `pg_index.indisvalid` and compare `pg_get_indexdef` against the expected definitions. The separate `idx_multi_asset_policy_name_hex` index is optional. A warning about it can be evaluated with the database owner while keeping the service login read-only.

[Midnight candidate index setup](https://github.com/midnightntwrk/midnight-node/blob/node-2.1.101/primitives/mainchain-follower/src/data_source/candidates_data_source/mod.rs#L138-L147) · [PostgreSQL TLS configuration](https://www.postgresql.org/docs/17/ssl-tcp.html)

## Start the Midnight PreProd archive node

Download the official `midnight-node-2.1.101-linux-amd64.tar.gz` release. Verify it against the release SHA-256 `48ce9d44464117b4ee8c1194209ebbbc4ea7d1adc39a77edeef1d1aa2b3ffbb5`. Extract the binary and its bundled `res` directory into `/opt/midnight-node/2.1.101`. Create a `midnight-node` system account and give it ownership of `/srv/midnight/midnight-node` on the mounted data volume. [Midnight release](https://github.com/midnightntwrk/midnight-node/releases/tag/node-2.1.101)

Set `/opt/midnight-node/2.1.101` as the working directory in `midnight-node.service` so the node can find `res/cfg/preprod.toml`. Set `User=midnight-node`, `EnvironmentFile=/etc/midnight/midnight-node.env`, `RequiresMountsFor=/srv/midnight`, and `ConditionPathIsMountPoint=/srv/midnight`. Order startup after PostgreSQL and DB Sync. Set `Restart=on-failure` and bind RPC to loopback with the following command and environment.

```bash
CFG_PRESET=preprod CARDANO_SECURITY_PARAMETER=2160 \
SSL_ROOT_CERT=/etc/midnight/postgres-ca.crt \
/opt/midnight-node/2.1.101/midnight-node \
  --chain /opt/midnight-node/2.1.101/res/preprod/chain-spec-raw.json \
  --base-path /srv/midnight/midnight-node \
  --sync full --state-pruning archive --blocks-pruning archive \
  --rpc-port 9944 --rpc-methods Safe \
  --name midnight-preprod --pool-limit 35 --no-private-ip
```

Enable and start `midnight-node.service`. Check the current best and finalized heights using `chain_getBlockHash`, `chain_getFinalizedHead`, and `chain_getHeader` on `http://127.0.0.1:9944`. For live-tip verification, require an advancing finalized height, `system_health` with peers and `isSyncing: false`, and a block hash that matches a recent finalized public PreProd block at the same height. Check that an older block and its historical runtime are available before starting the indexer. [Midnight full-node guide](https://docs.midnight.network/nodes/full-node) · [PreProd explorers](https://docs.midnight.network/relnotes/network#preprod)

### Archive replay observations

On 16 November 2026, PostgreSQL reported all three required indexes valid and ready. The archive service started, opened loopback RPC, and began replaying with peers. The following evidence records early archive replay from genesis.

| Observation time (UTC) | Best height | Finalized height | Finalized block hash |
|---|---:|---:|---|
| 2026-11-16 23:03:31 | 6,112 | 5,972 | `0xd49fc69c955ab467e7a7fa542c4d24a61d37dafad42f645defc689cedbfebfa2` |
| 2026-11-16 23:04:41 | 16,161 | 16,108 | `0x0c7449598f6c2d943a3f7b29ed0640829e266512c4b165c3d0d19f476bc998af` |
| 2026-11-17 06:09:30 | 836,956 | 836,799 | `0x7a546dc2bcda78c812ecf4093e1cf9258b00f3ec25f23686a5e2fda94f92bd6b` |

At 06:09 UTC the archive node reported major sync with 13 peers and a peer target of 3,454,422.

## Start the standalone Midnight indexer

For this lab, the indexer started during archive replay to overlap the two workloads. First verify the PreProd genesis hash `0xdf831b09a8baa92badf47762ce5ac439b7e47e3ed3d39600cfdd44fad552361b` and confirm both `chain_getBlock` and `state_getRuntimeVersion` return data for an older block. The archive returned bodies and runtime state for genesis and block 1,000 at 06:18 UTC. The indexer replays the node's finalized history, then follows new finalized blocks. Its `/ready` endpoint measures progress against its local archive node. Use the public same-height hash check in the previous section to establish live PreProd catch-up. [Indexer release](https://github.com/midnightntwrk/midnight-indexer/releases/tag/v4.4.101) · [Replay implementation](https://github.com/midnightntwrk/midnight-indexer/blob/v4.4.101/chain-indexer/src/infra/subxt_node.rs#L392-L527)

1. Install Ubuntu's `docker.io` package and enable `docker.service`. Verify `/srv/midnight` is mounted. Create `/srv/midnight/midnight-indexer` owned by `10001:10001` with mode `0750`. The bind mount at `/data` persists both SQLite databases.
2. Generate a stable 32-byte hex encryption key at `/etc/midnight/indexer/secret`. Use a root-owned parent directory, UID `10001` for the file, and mode `0400`. Mount this file read-only. Keep the same key with the indexer data through service restarts.
3. Create the container using the pinned image and environment. Host networking lets it connect to the node's loopback RPC on Linux. Explicitly bind the GraphQL listener to loopback. The dummy Blockfrost setting is for this lab's block indexing, and a real SPO integration needs a separate review of credentials and logging.

```bash
docker create --name midnight-indexer --network host \
  --cap-drop ALL --security-opt no-new-privileges \
  --cpu-shares 256 --memory-reservation 6g \
  --log-driver json-file --log-opt max-size=20m --log-opt max-file=3 \
  --mount type=bind,src=/srv/midnight/midnight-indexer,dst=/data \
  --mount type=bind,src=/etc/midnight/indexer/secret,dst=/run/secrets/indexer_secret,readonly \
  -e APP__INFRA__SECRET_FILE=/run/secrets/indexer_secret \
  -e APP__APPLICATION__NETWORK_ID=preprod \
  -e APP__INFRA__NODE__URL=ws://127.0.0.1:9944 \
  -e APP__INFRA__SPO_NODE__URL=ws://127.0.0.1:9944 \
  -e APP__INFRA__SPO_NODE__BLOCKFROST_ID=dummy-not-using-spo \
  -e APP__INFRA__API__ADDRESS=127.0.0.1 \
  -e APP__INFRA__API__PORT=8088 \
  midnightntwrk/indexer-standalone:4.4.101@sha256:119f35db548ba1c390845f215bb1e928e73038bef7c315825aee0461bd54499d
```

4. Enable `midnight-indexer.service` with `Requires=` and `After=` for Docker and the archive node, `RequiresMountsFor=/srv/midnight`, and `ConditionPathIsMountPoint=/srv/midnight`. Set `ExecStart=/usr/bin/docker start --attach midnight-indexer`, `ExecStop=/usr/bin/docker stop --time 45 midnight-indexer`, and `Restart=always`. The first indexer process stopped during a container runtime restart. It resumed and the API was live on loopback afterward.

### Indexer and archive evidence

Query `{ block { height hash timestamp protocolVersion } }` at `http://127.0.0.1:8088/api/v4/graphql`. Use `chain_getBlockHash` on the archive node with the indexed block height. The table shows two advancing GraphQL samples whose hashes matched the archive RPC, ignoring the `0x` prefix. [Indexer GraphQL API](https://github.com/midnightntwrk/midnight-indexer/blob/v4.4.101/docs/api/v4/api-documentation.md)

| Observation time (UTC) | Indexer height | GraphQL and archive RPC matching hash | Archive finalized height |
|---|---:|---|---:|
| 2026-11-17 06:21:51 | 2,792 | `acd1c889d858c457874d5ac25c00bf868eb76f2fea28c2225c6881f50986550d` | 845,402 |
| 2026-11-17 06:23:12 | 7,580 | `e01df2ca60a87a82967411268fd9ad74af09b27cda63f6bbbf2191b2999e1061` | 846,336 |

The archive finalized hashes at those heights were `0xd50fa8e7b5ae8498bf2585af3215e2bb63c073c6a55bd32197c8dfc76f9d7b79` and `0x6a03a1d67f157f138c6c6e63741af4fdb5f8691822d6103dca95c5f2e3898844`, respectively. `/live` returned `200` and `/ready` returned `503` in both samples. At 06:23 UTC the archive peer target was 3,454,549. The archive and indexer were still replaying. On final catch-up, compare a fresh public Midnight PreProd finalized hash against the archive at the same height and repeat the GraphQL checks with `/ready` returning `200`.

## Verify monitoring and the health checker

Deploy the [monitoring configuration](monitoring/README.md) with the verified Prometheus image `prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06`. The live container uses Linux host networking, binds `127.0.0.1:9090`, and stores limited-retention data at `/srv/midnight/prometheus`. Mount `prometheus.yml` and `alerts.yml` read-only.

- At 06:23:47 UTC Prometheus reported `up=1` for `127.0.0.1:9615`. The stall, low-peer, and telemetry alerts all evaluated with health `ok` and state `inactive`.
- The [health checker](scripts/README.md) reported `syncing` with an empty issue array at 06:23:48 UTC. Best height advanced 487 and finalized height advanced 270 since the preceding observation.
- At 06:23:48 UTC Cardano DB Sync still matched the Cardano relay at height 5,422,132, slot 139,213,426, and hash `27d21811f2454d4f1e71624f3831910ff26e3d19f659d26031df9eb55e7bc4ca`.

## Direct Grafana access and CloudWatch

On 17 November 2026, Grafana `13.3.1` was deployed behind Nginx on the same EC2 host. The direct HTTPS health endpoint returned `database: ok` from the operator network. An anonymous request to `/api/user` returned `401`, and the HTTP `/login` path returned `404`. The Grafana backend, Prometheus, and Node Exporter were confirmed on loopback. The Let's Encrypt IP certificate renewal dry run passed and executed the Nginx reload hook. See the [Grafana guide](monitoring/grafana/README.md) for sign-in and queries.

Both provisioned dashboards loaded. The `midnight-node` and `node` Prometheus targets returned `up=1`, and the indexer hash probe returned `1`. Grafana queried native EC2 CPU metrics and the `/midnight/preprod/host` CloudWatch log group successfully. The log group received an indexer stream verification event and retains events for seven days.

| Replay observation (UTC) | Midnight finalized height | Indexer height | Indexer hash matches node |
|---|---:|---:|---|
| 2026-11-17 06:43:43 | 862,894 | 76,684 | Yes |
| 2026-11-17 06:58:59 | 877,689 | 115,170 | Yes |

At 06:59 UTC, Cardano relay and DB Sync matched at height 5,422,236 and hash `a5b57c5325300591a078cd25d6969a629e18d4eba9b87bdce41b2b086c50ec65`. Both Midnight services continued replaying. The indexer returned `/live=200` and `/ready=503`, and the data volume had 348 GiB free.

### Repeat replay and public hash check

| Observation (UTC) | Archive best | Archive finalized | Peer target | Indexed height | Same-height archive and indexer hash match |
|---|---:|---:|---:|---:|---|
| 2026-11-17 07:19:12 | 885,584 | 885,489 | 3,455,067 | 158,225 | Yes |
| 2026-11-17 07:20:43 | 886,345 | 886,272 | 3,455,081 | 161,119 | Yes |
| 2026-11-17 07:25:14 | 890,026 | 889,989 | 3,455,124 | 169,970 | Yes |

At 07:19 UTC the archive checksum `0x95b053f4e0e4e01cac5ca825e45605f5aa1e3622ef236e8afe5c22f8a9902ea4` matched [public finalized block 885,489](https://midnight-preprod.subscan.io/block/885489). The indexer and archive checksum `0xa450a431b9e7a00a0545c075e971978e027cebfcbfc0e2df10372459cc65ad55` matched [public finalized block 158,225](https://midnight-preprod.subscan.io/block/158225). The [sampled public finalized tip](https://midnight-preprod.subscan.io/block/3455067) was 3,455,067. The archive reported 10 peers and `isSyncing=true`. The indexer returned `/live=200` and `/ready=503` in both samples. The 07:20 UTC Cardano probe reported a same-height hash match at 5,422,294.

At 07:25 UTC the local archive hash `0x38c7c9d66995028646b9587c375e337cbb7b8a8d058d403b00e32252ceef2216` matched [public block 889,989](https://midnight-preprod.subscan.io/block/889989). The indexer hash `0x4ede69b5f9fb83b00a9c1865994f09996b9c33f16be13850b461586b1a2a185d` matched the local archive and [public block 169,970](https://midnight-preprod.subscan.io/block/169970). The archive still reported major sync and the indexer returned `/live=200` and `/ready=503`.

Grafana loaded all four dashboards from file provisioning. The new Replay queries returned fresh heights, progress percentages, backlog drain rates, and peer count. The AWS dashboard returned EC2 CPU, status checks, network data, and data-volume operations, throughput, and queue depth. The volume-level IOPS and throughput exceeded checks returned no points in the verification window. Logs Insights returned a warning and error keyword series and 100 collected events in the latest-events panel.
