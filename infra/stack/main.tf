data "aws_ami" "ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  name     = "midnight-stack-${var.environment}"
  data_dir = "/srv/midnight"

  networks = {
    preview = { cardano_magic = 2, cardano_security_parameter = 432, minimum_gib = 250 }
    preprod = { cardano_magic = 1, cardano_security_parameter = 2160, minimum_gib = 500 }
    mainnet = { cardano_magic = null, cardano_security_parameter = 2160, minimum_gib = 3000 }
  }
  network = local.networks[var.environment]

  # Signed release pins belong in the application installer when it is added.
  versions = {
    cardano_relay    = "11.0.1"
    cardano_db_sync  = "13.7.1.0"
    midnight_node    = "2.1.101"
    midnight_indexer = "4.4.101"
  }

  public_tcp_egress_ports = setunion(var.cardano_peer_ports, toset([80, 443, 30333]))
  secret_arns             = distinct(compact(values(var.secret_arns)))
}

module "cardano_relay" {
  source         = "./modules/service"
  name           = "cardano-node"
  data_directory = "${local.data_dir}/cardano"
}

module "db_sync" {
  source         = "./modules/service"
  name           = "cardano-db-sync"
  data_directory = "${local.data_dir}/db-sync"
  required_units = ["${module.cardano_relay.component.name}.service", "postgresql@17-main.service"]
  preflight      = "cardano"
  loopback_ports = [5432]
  credentials    = { pgpass = var.secret_arns.db_sync_pgpass }
}

module "midnight_node" {
  source         = "./modules/service"
  name           = "midnight-node"
  data_directory = "${local.data_dir}/midnight-node"
  required_units = ["${module.db_sync.component.name}.service"]
  preflight      = "db-sync"
  loopback_ports = [9944]
  credentials = {
    postgres-dsn = var.secret_arns.midnight_pg_dsn
    p2p-key      = var.secret_arns.midnight_p2p_key
  }
}

module "midnight_indexer" {
  source         = "./modules/service"
  name           = "midnight-indexer"
  data_directory = "${local.data_dir}/midnight-indexer"
  required_units = ["${module.midnight_node.component.name}.service"]
  preflight      = "midnight-node"
  loopback_ports = [8088]
  credentials = {
    indexer-secret = var.secret_arns.indexer_secret
    blockfrost-id  = var.secret_arns.indexer_blockfrost
  }
}

resource "aws_vpc" "stack" {
  # checkov:skip=CKV2_AWS_11:Single-host assessment outline omits billable flow logs. Enable in production.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_default_security_group" "closed" {
  vpc_id = aws_vpc.stack.id
}

resource "aws_subnet" "stack" {
  vpc_id                  = aws_vpc.stack.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.stack.id
}

resource "aws_route_table" "egress" {
  vpc_id = aws_vpc.stack.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.egress.id
  }
}

resource "aws_route_table_association" "stack" {
  subnet_id      = aws_subnet.stack.id
  route_table_id = aws_route_table.egress.id
}

resource "aws_security_group" "host" {
  name        = local.name
  description = "Outbound P2P, HTTPS and package access. Administer via Session Manager."
  vpc_id      = aws_vpc.stack.id
  ingress     = []

  dynamic "egress" {
    for_each = local.public_tcp_egress_ports
    content {
      description = "Outbound TCP ${egress.value} for peers, AWS services, or package repositories"
      from_port   = egress.value
      to_port     = egress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}

resource "aws_iam_role" "host" {
  name_prefix = "${local.name}-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets" {
  count = length(local.secret_arns) > 0 ? 1 : 0
  name  = "fetch-stack-credentials"
  role  = aws_iam_role.host.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = local.secret_arns
    }]
  })
}

resource "aws_iam_instance_profile" "host" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.host.name
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.stack.availability_zone
  type              = "gp3"
  size              = var.data_volume_gib
  encrypted         = true
  snapshot_id       = var.data_snapshot_id

  tags = { Name = "${local.name}-data" }

  lifecycle {
    precondition {
      condition     = var.data_volume_gib >= local.network.minimum_gib
      error_message = "The environment requires at least ${local.network.minimum_gib} GiB in this model."
    }
  }
}

resource "aws_instance" "host" {
  # checkov:skip=CKV_AWS_88:Public IPv4 for outbound P2P and SSM without NAT cost. The instance security group has zero ingress.
  # checkov:skip=CKV_AWS_126:Assessment uses standard EC2 metrics. Enable paid detailed monitoring if needed in production.
  # checkov:skip=CKV_AWS_135:The lab can be torn down. The data volume is a separate resource.
  ami                         = var.ami_id == null ? data.aws_ami.ubuntu[0].id : var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.stack.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  user_data                   = "#cloud-config\n${yamlencode(local.cloud_config)}"
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = local.name }

  depends_on = [aws_route_table_association.stack, aws_iam_role_policy_attachment.ssm]
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  instance_id = aws_instance.host.id
  volume_id   = aws_ebs_volume.data.id
}

output "components" {
  description = "Four ordered runtime component contracts and their pinned network configuration."
  value = {
    network  = var.environment
    settings = local.network
    versions = local.versions
    services = local.components
  }
}
