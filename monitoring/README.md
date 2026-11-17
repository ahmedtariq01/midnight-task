# Midnight PreProd monitoring

Prometheus scrapes the node's native metrics at `127.0.0.1:9615/metrics` every 30 seconds. The rules use the `midnight_preprod` chain label seen on the EC2 node. The archive node follows PreProd and imports blocks, so best block height is the progress signal during replay and after catch-up. Finalized height and the sync target help explain a stall.

## Alerts

| Alert | Why it fires | Operator response |
| --- | --- | --- |
| `MidnightBlockImportStalled` | Best height shows no net advance across 10 minutes with at least 18 samples, and this condition persists for 2 minutes. This allows for scrape gaps and avoids treating a new target or short pauses as stalls. | Compare best and finalized heights with the public PreProd tip. Check service logs, disk free space and I/O, and peer health. If the network is also stationary, investigate the network before restarting the node. |
| `MidnightPeerCountLow` | Fewer than three connected peers for 5 minutes. Brief connection churn is expected. Sustained loss of peer diversity can leave the node dependent on a single peer or isolated. | Check discovery, outbound P2P connectivity, and the configured PreProd bootnodes. Look for handshake errors, then confirm peers and block import recover. |
| `MidnightTelemetryUnavailable` | For 2 minutes the target is missing, the scrape fails, or the response lacks the expected best-height or peer gauge. Height and peer alerts require a successful scrape. | Check Prometheus targets, `systemctl status midnight-node.service`, and the loopback metrics response. An HTTP 200 without the expected series calls for checking the chain label and node version. If the process is down, inspect the journal and disk before restarting it. |

Metrics availability measures the scrape endpoint. The [node health checker](../scripts/README.md) covers JSON-RPC. Check indexer readiness at `/ready`. Prometheus exposes firing alerts in its local UI and API. External alert delivery and detection of the EC2 host's own outage require an off-host collector or receiver.

## Validate locally

Run from the repository root with Prometheus `promtool`.

```sh
promtool check config monitoring/prometheus.yml
promtool test rules monitoring/alerts.test.yml
```

The tests cover advancing and stalled import, a transient and a sustained peer dip, recovery, a failed scrape, missing metrics, and a missing target.

## Run and inspect

Run Prometheus on the EC2 host with its web UI bound to loopback. Use a writable directory outside the checkout for its data.

```sh
prometheus --config.file=monitoring/prometheus.yml \
  --web.listen-address=127.0.0.1:9090 \
  --storage.tsdb.path="$PROMETHEUS_DATA_DIR" \
  --storage.tsdb.retention.time=3d \
  --storage.tsdb.retention.size=1GB
```

Run these checks on the EC2 host. The first confirms that the gauges are present. The next two show the scrape health and current alerts. The Prometheus web UI can also be viewed through a Session Manager port-forward to port 9090.

```sh
curl -fsS --max-time 5 http://127.0.0.1:9615/metrics |
  grep -E '^substrate_(block_height|sub_libp2p_peers_count)\{'
curl -fsSG --max-time 5 --data-urlencode 'query=up{job="midnight-node"}' http://127.0.0.1:9090/api/v1/query
curl -fsS --max-time 5 http://127.0.0.1:9090/api/v1/alerts
```
