data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_ec2_instance_type_offerings" "selected" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_ami" "ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name = "midnight-preprod"

  offered_zones = sort(tolist(setintersection(
    data.aws_availability_zones.available.names,
    data.aws_ec2_instance_type_offerings.selected.locations,
  )))
  availability_zone = var.availability_zone != null ? var.availability_zone : try(local.offered_zones[0], null)
  ami_id            = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.77.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.77.0.0/26"
  availability_zone = local.availability_zone

  tags = { Name = "${local.name}-public" }

  lifecycle {
    precondition {
      condition     = local.availability_zone == null ? false : contains(local.offered_zones, local.availability_zone)
      error_message = "Select an enabled Availability Zone that offers the requested instance type."
    }
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = { Name = local.name }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "node" {
  name        = "${local.name}-node"
  description = "PreProd host managed through Session Manager"
  vpc_id      = aws_vpc.lab.id
}

resource "aws_vpc_security_group_egress_rule" "outbound_tcp" {
  security_group_id = aws_security_group.node.id
  description       = "Public Cardano peers, Session Manager, and software downloads"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
}

resource "aws_iam_role" "node" {
  name_prefix = "${local.name}-ec2-"

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
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.node.name
}

resource "aws_instance" "node" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.node.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${local.name}-root" }
  }

  tags = { Name = local.name }

  depends_on = [aws_route_table_association.public, aws_iam_role_policy_attachment.ssm]
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  type              = "gp3"
  size              = var.data_volume.size_gib
  iops              = var.data_volume.iops
  throughput        = var.data_volume.throughput_mib
  encrypted         = true

  tags = { Name = "${local.name}-data" }
}

resource "aws_volume_attachment" "data" {
  # Linux exposes EBS on Nitro as NVMe. Identify the data disk by EBS volume ID.
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.node.id
}
