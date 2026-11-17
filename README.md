# Midnight PreProd DevOps take-home

This project runs the Cardano dependencies, Midnight PreProd archive node, standalone indexer, and Prometheus on a single On-Demand EC2 instance in Ohio. The lab exercises validator onboarding operations using a public archive node. Validator registration on PreProd requires operator access from the network team.

| Component | Version | Evidence |
|---|---|---|
| Cardano relay | `11.0.1` | PreProd relay tracked the live tip. |
| Cardano DB Sync and PostgreSQL | `13.7.1.0` and `17` | Two PostgreSQL heights and hashes matched the Cardano relay after the near-tip migrations. |
| Midnight archive node | `2.1.101` | At 07:20 UTC on 17 November it had finalized 886,272 blocks and was still replaying. An earlier finalized hash at 885,489 matched public PreProd. |
| Midnight standalone indexer | `4.4.101` | At 07:20 UTC it had indexed 161,119 blocks and its hash matched the archive at that height. `/live` returned `200` and `/ready` returned `503` during replay. |

The [runbook](RUNBOOK.md) records the bootstrap, database TLS setup, and timestamped verification. The [infrastructure guide](infra/README.md) documents the network, storage, Terraform outline, and CI. The [security notes](SECURITY.md) cover operator key custody, rotation, and incident response.

## PreProd data flow

Cardano DB Sync has to reach the Cardano relay tip before the Midnight archive starts. The indexer then reads the archive's finalized history and follows new finalized blocks. The replay probes compare heights and hashes across the local services.

```mermaid
flowchart LR
    CardanoPeers["Cardano PreProd peers"] --> Relay["Cardano relay"]
    Mithril["Mithril snapshot"] -.->|Verified bootstrap| Relay
    Relay -->|Unix socket| DBSync["Cardano DB Sync"]
    DBSync -->|Indexes Cardano blocks| Postgres["PostgreSQL 17 · cexplorer"]
    Postgres -->|Read-only queries over TLS| Archive["Midnight PreProd archive"]
    MidnightPeers["Midnight PreProd peers"] -->|Blocks| Archive
    Archive -->|Finalized history over loopback WebSocket| Indexer["Standalone indexer"]
    Indexer -->|Persists indexed state| SQLite["SQLite on EBS"]
    Relay -.->|Tip height and hash| Probes["Read-only replay probes"]
    Postgres -.->|Indexed Cardano tip and hash| Probes
    Archive -.->|Finalized height and block hashes| Probes
    Indexer -.->|GraphQL, liveness and readiness| Probes
```

## AWS architecture

The workload runs on one On-Demand EC2 instance in Ohio. The operator reaches the shell through Session Manager and Grafana through Nginx on the instance's public IPv4 address. The security group limits HTTPS to the operator's IPv4 address. The HTTP listener serves ACME certificate validation only.

```mermaid
flowchart TB
    Operator["Operator"]
    LetsEncrypt["Let's Encrypt ACME validators"]
    Networks["Cardano and Midnight PreProd peers · Mithril"]

    subgraph AWS["AWS · Ohio (us-east-2)"]
        SSM["Systems Manager · Session Manager"]
        Role["EC2 instance profile<br/>SSM access and scoped CloudWatch permissions"]

        subgraph CW["Amazon CloudWatch"]
            Metrics["Native AWS/EC2 and AWS/EBS metrics"]
            Logs["CloudWatch Logs · /midnight/preprod/host<br/>7-day retention"]
        end

        subgraph VPC["Lab VPC · 10.77.0.0/24"]
            Internet["Internet gateway · public subnet default route"]
            subgraph Subnet["Public subnet · 10.77.0.0/26 · us-east-2a"]
                SG["EC2 security group · public IPv4<br/>443 from operator /32 · 80 for ACME"]
                subgraph EC2["On-Demand EC2 · c6a.4xlarge · Ubuntu 24.04"]
                    Nginx["Nginx TLS proxy · Certbot IP certificate"]
                    Grafana["Grafana · authenticated · loopback 3000"]
                    Prometheus["Prometheus · loopback 9090<br/>Three local alert rules"]
                    Exporter["Node Exporter · loopback 9100<br/>Host metrics and replay probe results"]
                    Workloads["Cardano relay · DB Sync · PostgreSQL<br/>Midnight archive · standalone indexer"]
                    Journal["systemd journal<br/>Includes a follower for indexer container logs"]
                    CWAgent["CloudWatch Agent"]
                    SSMAgent["SSM Agent"]
                end
                Root["Encrypted gp3 · 30 GiB root"]
                Data["Encrypted gp3 · 500 GiB data<br/>20,000 IOPS · 350 MiB/s · /srv/midnight"]
            end
        end
    end

    Operator -->|AWS console session| SSM
    Operator -->|HTTPS| Internet
    LetsEncrypt -->|HTTP-01 validation| Internet
    Internet --> SG
    SG --> Nginx
    Nginx -->|Loopback HTTP and WebSocket| Grafana
    SSMAgent -->|Outbound HTTPS via internet gateway| SSM
    Role -.->|IMDSv2 role credentials| SSMAgent
    Role -.-> Grafana
    Role -.-> CWAgent
    Workloads -->|Outbound peer and snapshot connections via internet gateway| Networks
    Grafana -->|PromQL| Prometheus
    Prometheus -->|Scrapes host and replay metrics| Exporter
    Prometheus -->|Scrapes Midnight native metrics on loopback 9615| Workloads
    Workloads -.->|Local read-only replay probes| Exporter
    Workloads -->|Service events| Journal
    Journal -->|Selected events| CWAgent
    CWAgent -->|Publishes logs| Logs
    Grafana -->|CloudWatch queries| Metrics
    Grafana -->|Logs Insights queries| Logs
    EC2 -.->|Native instance telemetry| Metrics
    Data -.->|Native volume telemetry| Metrics
    EC2 --- Root
    Workloads --- Data
    Prometheus --- Data
    Grafana --- Data
```

PostgreSQL, Midnight RPC, the indexer's GraphQL API, and the monitoring backends are reachable only on the host. The EC2 instance role supplies Grafana's CloudWatch read access and the agent's log publishing permissions. See the [EC2 configuration](infra/ec2/README.md) and [Grafana guide](monitoring/grafana/README.md).

## Monitoring

The Prometheus configuration targets the node on `127.0.0.1:9615`. The [monitoring guide](monitoring/README.md) explains the alert durations and checks. The alert choices reflect what an engineer can investigate directly on this host.

On EC2, the Prometheus target reported `up=1` and all three alert rules had evaluation health `ok`. The offline rules test also exercises firing and recovery.

The [Grafana setup](monitoring/grafana/README.md) provides four dashboards over HTTPS from the operator network. **PreProd Replay** shows block progress, readiness, and hash agreement. **PreProd Host and EBS** uses Prometheus for host and disk pressure. **PreProd AWS EC2 and EBS** adds native CloudWatch infrastructure metrics. **PreProd Service Logs** brings the collected CloudWatch service events into Grafana.

| Signal | Why it matters | Operator response |
|---|---|---|
| Block height stops advancing | The process can remain up while it stops importing blocks. | Check best and finalized heights, peers, node logs, and whether Cardano DB Sync is current. |
| Peer count stays low | A node with few peers has fewer routes to receive and validate new blocks. | Inspect bootnode connectivity, DNS, TCP `30333` egress, and peer churn. |
| Metrics scrape is unavailable | Node failure and metrics failure both remove monitoring visibility. | Check the systemd unit, restart history, and loopback metrics endpoint in Session Manager. |

```bash
promtool check config monitoring/prometheus.yml
promtool test rules monitoring/alerts.test.yml
```

## Health checker

Option C polls the node RPC, writes a structured report, and compares it with the previous observation. See the [health checker guide](scripts/README.md) for options and report fields. The RPC is bound to loopback, so run a live check on the EC2 host through Session Manager.

Two live health samples reported expected sync progress. The second reported no active issues and a 487-block increase in best height.

```bash
python3 scripts/node_health.py --rpc-url http://127.0.0.1:9944 \
  --interval 30 --output var/midnight-health.json
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

## CI and submission evidence

The [GitHub Actions workflow](.github/workflows/terraform.yml) checks formatting, validation, lint, security controls, Terraform assertions, Prometheus rules, and the health checker. PR validation uses the mocked PreProd plan shown in the Actions summary. The AWS apply path uses an approval-protected `preprod` environment and OIDC once the repository owner configures them.

The [passing GitHub Actions run](https://github.com/ahmedtariq01/midnight-task/actions/runs/44030108980) records the mocked PreProd plan, Terraform checks, Prometheus rule tests, and health checker tests. The deployment job was skipped. The runbook records live progression and same-height hashes. Full PreProd verification remains in progress while the archive and indexer replay.

## What I would do with more time

Test restoration from snapshots on a fresh host and measure how long each service takes to resume. Move operator signing to a separate host and monitor the deployment from a second machine so an EC2 outage can still trigger an alert. See the [infrastructure guide](infra/README.md#rebuild-and-production-changes).
