mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = { id = "ami-00000000000000001" }
  }

  mock_resource "aws_ebs_volume" {
    override_during = plan
    defaults        = { id = "vol-00000000000000001" }
  }
}

run "least_privilege_and_persistence" {
  command = plan

  assert {
    condition     = length(aws_security_group.host.ingress) == 0 && !aws_subnet.stack.map_public_ip_on_launch
    error_message = "The host must have no inbound rules and the subnet must not allocate public IPs by default."
  }

  assert {
    condition = length(aws_security_group.host.egress) > 0 && alltrue([
      for rule in aws_security_group.host.egress :
      rule.protocol == "tcp" && rule.from_port == rule.to_port && !contains([22, 5432, 8088, 9944], rule.from_port)
    ])
    error_message = "Public egress must only allow explicit destination TCP ports and exclude admin, database, and application ports."
  }

  assert {
    condition = (
      aws_instance.host.metadata_options[0].http_tokens == "required" &&
      aws_instance.host.root_block_device[0].encrypted &&
      aws_ebs_volume.data.encrypted &&
      aws_ebs_volume.data.type == "gp3" &&
      aws_ebs_volume.data.size >= local.network.minimum_gib
    )
    error_message = "The stack requires IMDSv2 and enough encrypted gp3 data capacity for the selected network."
  }

  assert {
    condition = (
      module.cardano_relay.component.name == "cardano-node" &&
      contains(module.db_sync.component.required_units, "cardano-node.service") &&
      contains(module.db_sync.component.required_units, "postgresql@17-main.service") &&
      module.db_sync.component.preflight == "cardano" &&
      contains(module.midnight_node.component.required_units, "cardano-db-sync.service") &&
      module.midnight_node.component.preflight == "db-sync" &&
      contains(module.midnight_indexer.component.required_units, "midnight-node.service") &&
      module.midnight_indexer.component.preflight == "midnight-node"
    )
    error_message = "The runtime must gate relay, DB Sync, Midnight, and indexer in that order."
  }

  assert {
    condition = alltrue([
      for component in values(local.components) :
      startswith(component.data_directory, "/srv/midnight/") && contains(component.required_units, "midnight-stack-storage.service")
    ])
    error_message = "Every application must wait for the EBS mount and write persistent data there."
  }
}

run "approved_secret_references_only" {
  command = plan

  variables {
    secret_arns = {
      db_sync_pgpass  = "arn:aws:secretsmanager:us-east-2:000000000000:secret:test-db-sync-pgpass-000000"
      midnight_pg_dsn = "arn:aws:secretsmanager:us-east-2:000000000000:secret:test-midnight-postgres-000000"
    }
  }

  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.secrets[0].policy).Statement[0].Resource) == toset([var.secret_arns.db_sync_pgpass, var.secret_arns.midnight_pg_dsn])
    error_message = "The host may only retrieve Secrets Manager values explicitly referenced by the configuration."
  }

  assert {
    condition = (
      strcontains(module.db_sync.drop_in.content, "LoadCredential=pgpass:/run/midnight-stack/credentials/cardano-db-sync/pgpass") &&
      strcontains(module.midnight_node.drop_in.content, "LoadCredential=postgres-dsn:/run/midnight-stack/credentials/midnight-node/postgres-dsn") &&
      contains(module.midnight_node.component.required_units, "midnight-stack-credentials@midnight-node.service")
    )
    error_message = "Each database credential should have a dedicated runtime fetch and systemd credential."
  }
}

run "rejects_undersized_preprod_storage" {
  command = plan

  variables {
    environment     = "preprod"
    data_volume_gib = 499
  }

  expect_failures = [aws_ebs_volume.data]
}
