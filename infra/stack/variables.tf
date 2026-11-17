variable "environment" {
  type        = string
  description = "Matching Cardano and Midnight network."

  validation {
    condition     = contains(["preview", "preprod", "mainnet"], var.environment)
    error_message = "Choose preview, preprod, or mainnet."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS Region for the outline stack."
}

variable "availability_zone" {
  type        = string
  description = "Availability Zone shared by the EC2 host and its data volume."
}

variable "vpc_cidr" {
  type        = string
  description = "Nonoverlapping IPv4 CIDR for the environment's VPC."
}

variable "subnet_cidr" {
  type        = string
  description = "IPv4 CIDR contained in the environment's VPC."
}

variable "instance_type" {
  type        = string
  description = "On-demand x86_64 instance type for the four services."
}

variable "ami_id" {
  type        = string
  default     = null
  description = "Release-tested Canonical Ubuntu 24.04 AMD64 AMI. Null discovers the latest matching image."
}

variable "data_volume_gib" {
  type        = number
  description = "Size of the encrypted volume shared by the chain and database directories."

  validation {
    condition     = var.data_volume_gib >= 250 && floor(var.data_volume_gib) == var.data_volume_gib
    error_message = "Provide an integer data volume size of at least 250 GiB."
  }
}

variable "data_snapshot_id" {
  type        = string
  default     = null
  description = "Optional trusted EBS snapshot containing the stack's ext4 data disk."
}

variable "cardano_peer_ports" {
  type        = set(number)
  default     = [3001]
  description = "Allowed outbound TCP ports for configured Cardano peers. Review against the chosen topology."

  validation {
    condition = length(var.cardano_peer_ports) > 0 && alltrue([
      for port in var.cardano_peer_ports : port >= 1 && port <= 65535 && floor(port) == port && !contains([22, 5432, 8088, 9944], port)
    ])
    error_message = "Specify at least one valid TCP destination port and exclude stack private listeners."
  }
}

variable "secret_arns" {
  type = object({
    db_sync_pgpass     = optional(string)
    midnight_pg_dsn    = optional(string)
    midnight_p2p_key   = optional(string)
    indexer_secret     = optional(string)
    indexer_blockfrost = optional(string)
  })
  default     = {}
  description = "Existing Secrets Manager secret ARNs. Use an empty object to plan the outline without secrets."

  validation {
    condition = alltrue([
      for arn in values(var.secret_arns) : arn == null ? true : can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[a-zA-Z0-9/_+=.@-]+$", arn))
    ])
    error_message = "Secret references must be exact Secrets Manager ARNs."
  }
}
