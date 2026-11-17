terraform {
  required_version = "= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
  }

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "midnight-assessment"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
