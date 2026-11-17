# Midnight PreProd DevOps take-home

This project runs the Cardano dependencies and a Midnight PreProd archive node on a single On-Demand EC2 instance in Ohio. The lab exercises validator onboarding operations using a public archive node. Validator registration on PreProd requires operator access from the network team.

| Component | Version | Evidence |
|---|---|---|
| Cardano relay | `11.0.1` | PreProd relay tracked the live tip. |
| Cardano DB Sync and PostgreSQL | `13.7.1.0` and `17` | Two PostgreSQL heights and hashes matched the Cardano relay after the near-tip migrations. |
| Midnight archive node | `2.1.101` | The service connected to PreProd peers and is advancing through historical blocks. |
| Midnight standalone indexer | `4.4.101` | Planned launch after archive catch-up is verified against PreProd. |

The [runbook](RUNBOOK.md) records the bootstrap, database TLS setup, and timestamped verification. The [infrastructure guide](infra/README.md) documents the network, storage, Terraform outline, and CI. The [security notes](SECURITY.md) cover operator key custody, rotation, and incident response.

## Monitoring

Prometheus scrapes the node on `127.0.0.1:9615`. The [monitoring guide](monitoring/README.md) explains the alert durations and checks. The alert choices reflect what an engineer can investigate directly on this host.

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

```bash
python3 scripts/node_health.py --rpc-url http://127.0.0.1:9944 \
  --interval 30 --output var/midnight-health.json
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

## CI and submission evidence

The [GitHub Actions workflow](.github/workflows/terraform.yml) checks formatting, validation, lint, security controls, Terraform assertions, Prometheus rules, and the health checker. PR validation uses the mocked PreProd plan shown in the Actions summary. The AWS apply path uses an approval-protected `preprod` environment and OIDC once the repository owner configures them.

The [workflow history](https://github.com/ahmedtariq01/midnight-task/actions/workflows/terraform.yml) records the GitHub checks. Final live evidence will include the archive hash comparison, the indexer's readiness status, and two advancing indexer heights checked against the node at the same heights.
