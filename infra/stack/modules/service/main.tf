terraform {
  required_version = "= 1.14.0"
}

variable "name" {
  type        = string
  description = "Name of the application systemd unit."
}

variable "data_directory" {
  type        = string
  description = "Persistent application data directory."
}

variable "required_units" {
  type        = list(string)
  description = "Services ordered before this application."
  default     = []
}

variable "preflight" {
  type        = string
  description = "Bounded readiness probe argument."
  default     = null
}

variable "loopback_ports" {
  type        = set(number)
  description = "TCP listeners that runtime configuration binds to loopback."
  default     = []
}

variable "credentials" {
  type        = map(string)
  description = "Map of credential filenames to existing Secrets Manager ARNs."
  default     = {}
}

locals {
  credential_sources = { for name, arn in var.credentials : name => arn if arn != null }
  credential_unit    = "midnight-stack-credentials@${var.name}.service"
  required_units = concat(
    ["midnight-stack-storage.service"],
    var.required_units,
    length(local.credential_sources) > 0 ? [local.credential_unit] : [],
  )
  service_config = concat(
    [
      "[Unit]",
      "Requires=${join(" ", local.required_units)}",
      "After=${join(" ", local.required_units)}",
      "RequiresMountsFor=${var.data_directory}",
      "",
      "[Service]",
      "Environment=STACK_DATA_DIRECTORY=${var.data_directory}",
    ],
    var.preflight != null ? [
      "TimeoutStartSec=6min",
      "ExecStartPre=+/usr/local/libexec/midnight-stack-ready ${var.preflight}",
    ] : [],
    [
      for name in keys(local.credential_sources) :
      "LoadCredential=${name}:/run/midnight-stack/credentials/${var.name}/${name}"
    ],
    [""],
  )
}

output "component" {
  description = "Service dependency, storage, and loopback listener contract."
  value = {
    name           = var.name
    data_directory = var.data_directory
    required_units = local.required_units
    preflight      = var.preflight
    loopback_ports = var.loopback_ports
  }
}

output "drop_in" {
  description = "Cloud-init file for the application systemd drop-in."
  value = {
    path        = "/etc/systemd/system/${var.name}.service.d/10-stack.conf"
    permissions = "0644"
    content     = join("\n", local.service_config)
  }
}

output "credential_config" {
  description = "Per-service secret identifiers for the local fetch unit."
  value = length(local.credential_sources) == 0 ? [] : [{
    path        = "/etc/midnight-stack/credentials/${var.name}.json"
    permissions = "0600"
    content     = jsonencode(local.credential_sources)
  }]
}
