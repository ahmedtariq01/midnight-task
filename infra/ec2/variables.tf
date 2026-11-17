variable "aws_region" {
  description = "AWS Region for the PreProd host and its data volume."
  type        = string
  default     = "us-east-2"
}

variable "availability_zone" {
  description = "Availability Zone to use. When null, select the first enabled zone offering the instance type."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "An x86-64 EC2 instance type sized for the Cardano and Midnight services."
  type        = string
  default     = "c6a.4xlarge"
}

variable "ami_id" {
  description = "Optional pinned regional Ubuntu 24.04 amd64 AMI ID. When null, resolve Canonical's current image."
  type        = string
  default     = null
}

variable "data_volume" {
  description = "Size and provisioned performance of the encrypted gp3 data volume."
  type = object({
    size_gib       = optional(number, 500)
    iops           = optional(number, 20000)
    throughput_mib = optional(number, 350)
  })
  default  = {}
  nullable = false
}
