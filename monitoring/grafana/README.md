# Grafana for PreProd

Grafana uses the existing Prometheus service. Run Grafana on the EC2 host network so provisioned queries reach `http://127.0.0.1:9090`. Bind Grafana to `127.0.0.1:3000` on the host with `GF_SERVER_HTTP_ADDR=127.0.0.1`. The browser opens the EC2 public IPv4 address over HTTPS through Nginx. Set `GF_SERVER_ROOT_URL` to that address, pass the forwarded HTTPS scheme and WebSocket headers, enable secure cookies, and keep Grafana's writable data on the mounted EBS volume.

The EC2 ingress rules allow HTTPS from the operator's IPv4 `/32` and HTTP for ACME validation. Nginx serves only `/.well-known/acme-challenge/` on HTTP and returns `404` for all other HTTP paths. Certbot uses the short-lived IP certificate profile and reloads Nginx via its deployment hook. The HTTPS port and the renewal dry run were verified from the live deployment.

Sign in as `admin`. Grafana reads the generated password from a protected file at startup. The operator retrieves it in their Session Manager terminal with `sudo cat /etc/midnight/grafana/secrets/admin-password`. Grafana account sign-up and anonymous access are disabled.

| Directory | Container mount |
| --- | --- |
| `monitoring/grafana/provisioning` | `/etc/grafana/provisioning`, read-only |
| `monitoring/grafana/dashboards` | `/var/lib/grafana/dashboards`, read-only |

Grafana loads the **PreProd** folder at startup and checks its provisioned dashboard directory every 30 seconds.

- **PreProd Replay** (`preprod-replay`) shows current best, finalized, indexed and peer-target heights, gaps and percentages, replay and backlog drain rates, connected peers, Cardano tip agreement, and probe freshness. The archive percentage uses the peer-reported target. The indexer percentage uses local finality. Both denominators move as new blocks arrive. The probe panels that compare heights and hashes require a successful reading from the last three minutes.
- **PreProd Host and EBS** (`preprod-host-ebs`) uses Node Exporter on the `node` job. Check single-core versus mean CPU load, memory pressure, and storage latency and queue depth alongside replay rates. Use `findmnt -no SOURCE /srv/midnight` on the host to identify which NVMe series belongs to the data volume.
- **PreProd AWS EC2 and EBS** (`preprod-aws`) uses native CloudWatch CPU, status check, network, EBS operations, bytes, queue depth, and limit-check metrics. The EC2 and EBS IDs are text variables. Replace `__PREPROD_INSTANCE_ID__` and `__PREPROD_DATA_VOLUME_ID__` in the deployed copy or enter them in the dashboard controls. Absent limit-check points leave a gap. The dashboard refreshes every five minutes.
- **PreProd Service Logs** (`preprod-service-logs`) queries `/midnight/preprod/host`. It shows warning and error keywords by service and the latest 100 selected events. It uses a 30-minute window and manual refresh to limit repeated Logs Insights scans. Widen the window for services that log less frequently.

The test suite in the [monitoring guide](../README.md) covers the three existing Prometheus alerts. Use Grafana's Alerting view to inspect the rules and Explore to query the underlying metrics.

## Verify after deployment

1. Confirm Grafana `/api/health` reports database status `ok`. Sign in and open **Dashboards → PreProd** to see the four provisioned dashboards when CloudWatch is configured.
2. In Explore query `up{job=~"midnight-node|node"}`. Both targets should report `1`. Query `midnight_ops_probe_success{job="node"}` and check that the Replay dashboard shows recent probe ages for Cardano and the indexer.
3. Check that archive heights, indexer height, and NVMe IOPS render as time series. Compare the timestamp with current replay activity. A live indexer can return HTTP `503` from `/ready` while it replays history.
4. Confirm the AWS dashboard has EC2 CPU and data-volume I/O points, and the service logs dashboard returns a recent event. Only selected journal events are shipped, so some streams may have no events in a short window.

## Extra Node Exporter panels

To inspect more host metrics, import [Node Exporter Full](https://grafana.com/grafana/dashboards/1860-node-exporter-full/) by dashboard ID `1860` and select **PreProd Prometheus** as its data source. Its default job is `node`.

## CloudWatch

Mount [the CloudWatch data source](optional/cloudwatch.yml) as an additional file at `/etc/grafana/provisioning/datasources/cloudwatch.yml` when the running Grafana service has an approved AWS role with the required read permissions. The file uses the AWS SDK credential chain in `us-east-2`. In Explore use the existing `AWS/EBS` volume metrics, `AWS/EC2` instance metrics, or the `/midnight/preprod/host` log group after log collection is active.

The live source returned both `AWS/EC2` CPU metrics and Logs Insights results. Use **Explore → PreProd CloudWatch → Logs**, select the host log group, and choose a short time window. The CloudWatch agent ships selected service journal events with seven-day retention. A separate journal reader follows the already running indexer container using `docker logs --follow`.

Use **Maximum** over the selected window for the volume and instance IOPS and throughput exceeded checks. Correlate with host disk latency, queue depth, and lower replay speed before attributing a slowdown to EBS limits.

[Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/) · [CloudWatch data source](https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/configure/) · [AWS EBS metrics](https://docs.aws.amazon.com/ebs/latest/userguide/using_cloudwatch_ebs.html)
