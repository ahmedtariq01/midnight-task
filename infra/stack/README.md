# Midnight stack Terraform outline

This stack models the four services on one on-demand Ubuntu 24.04 AMD64 EC2 instance in Ohio. Sharing a host preserves the Cardano local Unix socket that DB Sync needs and avoids extra instances, a NAT gateway, and a managed database for the assessment. The existing assessment instance was built separately under [infra/ec2](../ec2/README.md). This root has its own state and resource names.

```text
AWS Session Manager ── HTTPS ───────────────────────┐
Public Cardano and Midnight peers ← outbound P2P ──┤
                                                  │
     EC2 in one AZ · no security group ingress    │
     Cardano node ── Unix socket ──► DB Sync       │
                                        │         │
                      PostgreSQL 17 cexplorer     │
                           127.0.0.1:5432          │
                                        │ TLS     │
                                        ▼         │
                            Midnight archive node │
                                ws://127.0.0.1:9944
                                        │
                                        ▼
                            Indexer 127.0.0.1:8088
                                        │
     Encrypted gp3 at /srv/midnight ────┴─ chain and database data
```

Terraform creates the VPC, routing, zero-ingress security group, SSM instance role, EC2 host, and separate encrypted gp3 data volume. It renders the mount unit, service drop-ins, startup checks, and Secrets Manager credential fetch unit with cloud-init. The service module is instantiated separately for the Cardano relay, DB Sync, Midnight archive node, and standalone indexer. Each instance specifies its dependencies, persistent directory and private listener contract.

The outline ends at the runtime wiring. Follow the [setup runbook](../../RUNBOOK.md) to install and verify the signed releases and package dependencies, create the application service users, configure the actual service commands and bind addresses, and start them in order. Use the Ubuntu PostgreSQL 17 cluster name `17-main` and `/srv/midnight/postgresql/17/main` for its data. The modeled Midnight process uses full archive sync, and the indexer uses its own SQLite stores on the EBS disk. The generated drop-ins assume the unit names and socket in this root. Check the unit names and paths if adapting the runbook recipes to a new image.

## Environment profiles

| Network | Cardano CLI selector | Cardano security parameter | EC2 | Data disk |
|---|---|---:|---|---:|
| Preview | `--testnet-magic 2` | 432 | `c6a.2xlarge` | 250 GiB |
| PreProd | `--testnet-magic 1` | 2160 | `c6a.4xlarge` | 500 GiB |
| Mainnet | `--mainnet` | 2160 | `r6a.4xlarge` | 3,500 GiB |

The profiles set separate VPC CIDRs and default to `us-east-2a`. Verify EC2 availability, current chain size and growth, and budgets before deploying each profile. These are sizing assumptions, and the Mainnet profile is untested on AWS. The pinned versions are Cardano node `11.0.1`, Cardano DB Sync `13.7.1.0`, Midnight node `2.1.101`, and indexer `4.4.101`. Choose the matching network configs from those releases. Set `ami_id` to a reviewed regional image for deterministic planning. By default, the provider selects the latest matching Canonical image. The vendored service module is pinned by the repository revision used for the plan.

The EC2 public IPv4 address provides outbound peer discovery, package downloads and SSM at lower assessment cost than a NAT gateway. The security group has zero inbound rules. It allows TCP egress to approved peer destination ports and package or AWS endpoints on ports 80 and 443. Cardano peer ports come from `cardano_peer_ports`. Check them against the chosen topology. Use Session Manager for administration and local port forwarding for the API. FNO peering and its restricted network require the operator-supplied access and topology.

## Startup and credentials

1. Cloud-init enables the storage unit. It waits up to five minutes for the matching EBS NVMe device by volume ID, formats only an unpartitioned device with no filesystem signatures, mounts ext4, and creates the component directories. Set service ownership through the installer and confirm that PostgreSQL uses the mounted directory.
2. DB Sync waits for the relay and PostgreSQL service. Its preflight checks the Cardano socket and `pg_isready`. The privileged systemd preflight can read the Cardano socket and queries PostgreSQL locally via the `postgres` OS account and peer authentication.
3. The Midnight node waits until PostgreSQL's highest block height, slot, and hash match a fully synced Cardano tip sampled immediately before or after the SQL query. The node then connects to `cexplorer` as the dedicated read-only role with TLS certificate validation.
4. The indexer preflight waits for a reachable Midnight RPC with peers, `isSyncing=false`, and a non-genesis finalized block. It also requires the local height to meet the peer target when `system_syncState` reports one. Before first enabling the indexer, follow the runbook to compare the local Midnight node's block hash with the public PreProd finalized hash at the same height. The runtime gate only checks the local node. After the indexer catches up, verify `/ready`, its GraphQL height and hash, and an advancing subscription.

Each preflight tries for up to five minutes per service start. Cardano DB Sync and Midnight full archive sync can each take longer. Let the upstream service continue running, inspect its logs and tip, then retry `systemctl start` for the dependent unit when the gate is met. If storage bootstrap times out, verify the EBS attachment and retry the storage unit.

Supply existing exact Secrets Manager ARNs in `secret_arns`. The instance role can get the specified values. Terraform and cloud-init carry the ARNs. The per-service fetch unit loads each secret into root-only storage under `/run`. systemd makes the files available to the corresponding service via `LoadCredential`. The application unit or wrapper needs to connect the `pgpass` file to `PGPASSFILE`, read `postgres-dsn` into `DB_SYNC_POSTGRES_CONNECTION_STRING`, and pass the optional `p2p-key` file to `NODE_KEY_FILE`. Set indexer credential paths with `APP__INFRA__SECRET_FILE` and `APP__INFRA__SPO_NODE__BLOCKFROST_ID_FILE`. Set `SSL_ROOT_CERT` to the locally trusted PostgreSQL CA and install a server certificate with a matching name. If using customer-managed secret keys, scope `kms:Decrypt` to those keys in the final role. Rotate the DB and indexer credentials under the same Secrets Manager ARNs and restart the affected application to reload them. The instance role sets the shared trust boundary. Add separate principals for workloads that require isolation.

## Local checks and state

```bash
cd infra/stack
terraform init -backend=false -input=false
terraform fmt -check -recursive
terraform validate
tflint --init
tflint --recursive
checkov -d . --framework terraform --check CKV_AWS_3,CKV_AWS_8,CKV_AWS_24,CKV_AWS_25,CKV_AWS_79
terraform test -var-file=environments/preprod.tfvars.example -verbose -no-color
```

Terraform is pinned to `1.14.0` and the AWS provider to `6.73.0`, with checksums in the lock file. CI uses TFLint `0.64` and Checkov `3.4.5`. The mock test stages produce a plan without AWS credentials and assert that private listeners stay closed, the root and EBS data volumes are encrypted, the mount and readiness gates are ordered correctly, and the database secret permissions are limited to the selected ARNs. A negative case verifies that undersized PreProd storage fails. Run the same tests with `preview.tfvars.example` and `mainnet.tfvars.example` to verify those profiles.

For an approved AWS target, provision a versioned, encrypted, access-controlled S3 state bucket outside the stack. Copy the [example backend settings](environments/preprod.s3.hcl.example) to a deployment-specific configuration, set the approved bucket and environment-specific state key, and initialize with `terraform init -reconfigure -backend-config=/path/to/backend.hcl`. The root enables the native S3 lockfile. Grant the deployment role access to the state object and the corresponding `.tflock` object. Use the approved account and OIDC role for a real plan, and review the plan before applying it. [S3 backend and permissions](https://developer.hashicorp.com/terraform/language/backend/s3)

## Rebuild and production

- To shorten Cardano recovery, restore certified immutable chain files with Mithril where supported. For DB Sync, restore a trusted PostgreSQL backup matching the Cardano network and DB Sync schema with compatible ledger state, then replay the gap. Alternatively, supply a trusted application-consistent EBS snapshot formatted as expected by the mount unit. Verify network, versions, snapshot lineage and restore integrity before exposing the restored services. If restoring to a larger volume, grow the restored ext4 filesystem after mounting it.
- Cloud-init changes replace the EC2 host so bootstrap applies on first boot. The data volume is a separate Terraform resource, so the replacement host can reuse it. Reinstall the application runtime on the replacement host and take an application-consistent backup before state changes that replace or destroy the volume. Before production, add automated release installation, retention and tested restores, alerts for disk and sync lag, and an availability plan for Cardano, PostgreSQL and the indexer.
- Review monthly spend, confirm VPC service endpoints or a managed egress design if moving away from a public IPv4 address, add ingress only for agreed P2P requirements, and establish a scheduled drift check against the remote state.
