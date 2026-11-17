# Grafana for PreProd

Grafana uses the existing Prometheus service. Run Grafana on the EC2 host network so provisioned queries reach `http://127.0.0.1:9090`. Bind the Grafana UI to `127.0.0.1:3000` with `GF_SERVER_HTTP_ADDR=127.0.0.1` and use Session Manager port forwarding to open it. Keep Grafana's writable data directory persistent.

| Directory | Container mount |
| --- | --- |
| `monitoring/grafana/provisioning` | `/etc/grafana/provisioning`, read-only |
| `monitoring/grafana/dashboards` | `/var/lib/grafana/dashboards`, read-only |

The **PreProd** folder is populated on startup.

- **PreProd Replay** (`preprod-replay`) shows the archive, indexer, and Cardano sync paths. It uses native Midnight metrics from the `midnight-node` job and numeric health probes from the `node` job. The probe panels that compare heights and hashes require a successful reading from the last three minutes. The archive's peer target measures local replay progress. Indexer readiness and hash agreement refer to the local archive.
- **PreProd Host and EBS** (`preprod-host-ebs`) uses Node Exporter on the `node` job. Check single-core versus mean CPU load, memory pressure, and storage latency and queue depth alongside replay rates. Use `findmnt -no SOURCE /srv/midnight` on the host to identify which NVMe series belongs to the data volume.

The test suite in the [monitoring guide](../README.md) covers the three existing Prometheus alerts. Use Grafana's Alerting view to inspect the rules and Explore to query the underlying metrics.

## Verify after deployment

1. Confirm Grafana `/api/health` reports database status `ok`. Sign in and open **Dashboards → PreProd** to see both provisioned dashboards.
2. In Explore query `up{job=~"midnight-node|node"}`. Both targets should report `1`. Query `midnight_ops_probe_success{job="node"}` and check that the Replay dashboard shows recent probe ages for Cardano and the indexer.
3. Check that archive heights, indexer height, and NVMe IOPS render as time series. Compare the timestamp with current replay activity. A live indexer can show **Catching up** while it replays history.

## Extra Node Exporter panels

To inspect more host metrics, import [Node Exporter Full](https://grafana.com/grafana/dashboards/1860-node-exporter-full/) by dashboard ID `1860` and select **PreProd Prometheus** as its data source. Its default job is `node`.

## Optional CloudWatch

Mount [the CloudWatch data source](optional/cloudwatch.yml) as an additional file at `/etc/grafana/provisioning/datasources/cloudwatch.yml` when the running Grafana service has an approved AWS role with the required read permissions. The file uses the AWS SDK credential chain in `us-east-2`. In Explore use the existing `AWS/EBS` volume metrics, `AWS/EC2` instance metrics, or the `/midnight/preprod/host` log group after log collection is active.

Use **Maximum** over the selected window for the volume and instance IOPS and throughput exceeded checks. Correlate with host disk latency, queue depth, and lower replay speed before attributing a slowdown to EBS limits.

[Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/) · [CloudWatch data source](https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/configure/) · [AWS EBS metrics](https://docs.aws.amazon.com/ebs/latest/userguide/using_cloudwatch_ebs.html)
