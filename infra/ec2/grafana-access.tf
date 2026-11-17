variable "grafana_https_client_cidr" {
  type        = string
  default     = null
  description = "Single operator IPv4 /32 allowed to use the Grafana HTTPS proxy. Null disables HTTPS ingress."

  validation {
    condition = var.grafana_https_client_cidr == null ? true : (
      endswith(var.grafana_https_client_cidr, "/32") && can(cidrnetmask(var.grafana_https_client_cidr))
    )
    error_message = "Enter a single IPv4 address with /32, or null to disable Grafana ingress."
  }
}

variable "grafana_acme_http_enabled" {
  type        = bool
  default     = false
  description = "Enable TCP/80 for ACME HTTP-01 issuance and renewal. The guest HTTP listener must serve only the ACME challenge path."

  validation {
    condition     = !var.grafana_acme_http_enabled || var.grafana_https_client_cidr != null
    error_message = "Enable Grafana HTTPS for an operator IPv4 /32 before enabling its ACME HTTP challenge listener."
  }
}

resource "aws_vpc_security_group_ingress_rule" "grafana_https" {
  count = var.grafana_https_client_cidr == null ? 0 : 1

  security_group_id = aws_security_group.node.id
  description       = "Grafana HTTPS proxy for the operator IPv4 address"
  cidr_ipv4         = var.grafana_https_client_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "grafana_acme_http" {
  count = var.grafana_acme_http_enabled ? 1 : 0

  # ACME validators use changing IPs. Keep the Nginx port 80 vhost
  # challenge-only, with a 404 for every other path and no proxy.
  security_group_id = aws_security_group.node.id
  description       = "ACME HTTP-01 challenge validation and renewal only"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}
