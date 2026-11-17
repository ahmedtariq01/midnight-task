# Prompts and outputs

Selected prompts and responses from the assessment chat, in chronological order. Blockquotes preserve the original wording, with redactions marked in brackets. Repeated progress checks and private access exchanges are omitted. The linked repository files contain the implementation and timestamped verification.

## 1. Understand the brief and plan the work

**Prompts**

> understand this document completely and tell me clearly wha are we supposed to do, dont build anything for now

> Now give me a step-by-step plan for completing this, including what we need to start Cardano DB Sync and what we can do while it runs. Don’t build anything yet.

**Response excerpts**

> The overview says four sections, but the PDF contains five numbered sections. Treat all five as in scope

> Start Cardano DB Sync first, then use the overnight wait to complete most of the repository.

The plan put the long Cardano sync on the critical path and scheduled the monitoring, scripting, key management, and Terraform work in parallel. [Assessment overview](../README.md)

## 2. Choose and review the EC2 configuration

**Prompts**

> Can we run Cardano DB Sync on my Mac or do we need a cloud VM? Check my machine against the requirements and tell me what we need to get started. Don't install or provision anything yet.

> use the terraform to setup the ec2 and [private credential handling omitted] but dont deploy anything let me review first, althou can make the veification if the required vm exists in the ohio us, also show me the artitectual digram of what we are buiding so i can review and modify if required

> make sure we are picking the cheapest options for this asseesment

> if we go for the spot the chances are it might goes disallocated during the assessment so better stick with the on deman, amd thell me the terraform config u have setup for the ec2?

**Response excerpts**

> Your Mac can run Cardano DB Sync in Linux containers, but it doesn’t have enough free disk space today.

> Terraform validation passed, and the plan shows **13 additions, zero changes, and zero deletions**. Nothing was deployed.

The review compared Spot and On-Demand estimates. The operator chose an Ohio On-Demand `c6a.4xlarge` with 32 GiB RAM, encrypted 30 GiB root and 500 GiB data volumes, and Session Manager access. The estimate at the time was $9.68 for 12 hours including storage and public IPv4. [EC2 design and price estimate](../infra/ec2/README.md)

## 3. Provision the reviewed host

**Prompts**

> keep admin access via console for now, the plan looks good, go ahead and create

> i have updated your permission kindly check now

**Response excerpts**

> AWS denied `iam:CreateRole` when Terraform tried to set up the role required for Session Manager in the console. The apply stopped before launching the VM.

> The permission update worked. **`midnight-preprod` is running** as an On-Demand `c6a.4xlarge` in Ohio (`us-east-2a`). All three EC2 status checks passed, and Terraform reports **no pending changes**.

The retry reused the Terraform-managed network after the operator updated IAM permissions. [Deployment and Terraform review](../infra/ec2/README.md#deployment-and-terraform-review)

## 4. Start Cardano DB Sync and verify the live tip

**Prompts**

> alright go ahead and mount the 500GB disk on the EC2, set up Cardano PreProd and start DB Sync. make sure the block height is advancing before leaving it running overnight and before running give me the summary so i canr eview

> alright i have reviewed the docs and reading it and you Go ahead. Mount the 500 GiB disk, set up Cardano PreProd and start DB Sync via Session Manager. Show me two timestamped PostgreSQL block heights confirming it’s advancing, then leave it running overnight.

> alright can you check DB Sync against the live PreProd tip again? if it’s caught up, show me the Midnight node and indexer plan before running anything. if it’s still behind, give me an updated ETA.

**Response excerpts**

> The 500 GiB EBS disk is mounted persistently at `/srv/midnight`. Cardano, PostgreSQL 17, and DB Sync are active under `systemd` and enabled at boot.

> PostgreSQL finished all nine near-tip migrations, then matched the relay’s block height and hash as new blocks arrived.

| UTC on 16 November 2026 | PostgreSQL block height | What the check showed |
|---|---:|---|
| 17:21:17 | 180,603 | First indexing sample |
| 17:21:47 | 205,336 | Advanced by 24,733 blocks in 30 seconds |
| 22:35:43 | 5,420,843 | Height and hash matched the live relay |
| 22:36:43 | 5,420,848 | Height and hash matched again at a newer block |

The reviewed Midnight plan used a dedicated read-only PostgreSQL login over TLS, an archive node retaining historical state, and a standalone indexer using the archive’s local WebSocket. [Cardano evidence](../RUNBOOK.md#live-preprod-evidence) · [Midnight database setup](../RUNBOOK.md#prepare-midnights-postgresql-connection)

## 5. Run Midnight and prepare the submission in parallel

**Prompts**

> alright the plan looks good, go ahead on the same EC2 via Session Manager. Verify the Midnight node catches up before starting the indexer, then show me the block height and hash checks for both.

> until the sync part is done can u do the rest so we can save time? first give me the details of what we can do?

> yes i have reviewed u can prepare rhe rest

> logged in done,  repo created, use my user name to setup the hings [https://github.com/ahmedtariq01/midnight-task](https://github.com/ahmedtariq01/midnight-task)

> it is still time conusiming righ? A fresh tip check is still required before launching the live indexer. we can just run the indexer if that makes sensn

> How much of the assessment can be completed by 10?

**Response excerpts**

> The repository includes the runbook and live evidence, monitoring and three alert rules, the health checker, the key-management write-up, and the Terraform outline.

> It’s replaying alongside the archive node. Full PreProd catch-up still depends on the archive’s pace and may extend past Wednesday’s meeting.

After the follow-up, the indexer started during archive replay. At launch the archive served the PreProd genesis hash, historical block bodies, and historical runtime state. On 17 November at 06:21:51 and 06:23:12 UTC, the indexer advanced from 2,792 to 7,580 and matched the archive hash at each indexed height. The indexer’s `/ready` endpoint returned `503` during replay. The assessment CI checks passed and the gated AWS apply was skipped. [Replay evidence](../RUNBOOK.md#indexer-and-archive-evidence) · [CI and submission evidence](../README.md#ci-and-submission-evidence)

## 6. Add secure Grafana access and CloudWatch

**Prompts**

> How we can optimised the setup and yes the Prometheus is there but not helpful for me I’m think of setting up Graphana for infra morning  and custom or prebuilt graphs for the better viisulozation of the metrics and logs along with cloud watch for monitor and logging as well??? Since we don’t have the dns so the ec2 vm k be use to access the grafana dashboard?

> Keep the default admin creds for grafana as well, also need to make sure that our setup is secure

> Not bind to my localhost

> Have nginx server if required

> Ok we have locked the configuration of monitoring now proceed with the setup make sure it’s ready along with that monitor the running jobs in the ec2

**Response excerpts**

> Nginx serves trusted HTTPS, and the certificate renewal dry run passed. The Grafana and Prometheus ports stay private on EC2.

> I also verified that Grafana can query EC2 metrics and CloudWatch Logs.

The operator could connect directly to Nginx over HTTPS from an allowlisted address. Grafana retained the `admin` username and used a generated password. The Prometheus-backed dashboards loaded, and Grafana queried native EC2 metrics and the seven-day service log group. Between 06:43:43 and 06:58:59 UTC on 17 November, the archive’s finalized height advanced from 862,894 to 877,689 and the indexer advanced from 76,684 to 115,170. Both indexed heights matched the archive's same-height hashes. [Grafana setup](../monitoring/grafana/README.md) · [Live monitoring evidence](../RUNBOOK.md#direct-grafana-access-and-cloudwatch)

## 7. Review what was left and improve the dashboards

**Prompts**

> What is now remaining from the assessment make the checklist

> improve the preprod replay and amke it more information and create other dashbaords i required. Also check if the Midnight node and indexer have caught up now. and i have provided the clowwwach metrics required access or is it done? and in the readme file also add the architture flow diagram also the aws rchitecture diagram including everything the moiitnging logging as welll

> also create a prompt folder and include the prompts i used and the outputs i got, and also ref that in the readme sot he reviewer can view it

**Checklist response excerpt**

> The assessment asks for evidence that the node is running and syncing, and that evidence is already in the repo.

The checklist identified confirming archive finality against public PreProd and getting indexer `/ready=200` with a fresh hash match as live follow-up.

**Verification outputs**

- At 07:25:14 UTC on 17 November, the archive finalized block 889,989 against a peer target of 3,455,124. The indexer was at 169,970 with `/live=200` and `/ready=503`. Hashes agreed with public PreProd at both sampled heights. [Replay verification](../RUNBOOK.md#repeat-replay-and-public-hash-check)
- Four dashboards loaded in Grafana. The replay queries returned fresh metrics, native CloudWatch CPU and EBS I/O returned data, and the latest-events panel returned 100 collected log rows. [Grafana dashboards](../monitoring/grafana/dashboards/)
- Two Mermaid diagrams document the workload and monitoring paths. [PreProd data flow](../README.md#preprod-data-flow) · [AWS architecture](../README.md#aws-architecture)
