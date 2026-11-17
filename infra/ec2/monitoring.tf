variable "enable_cloudwatch_monitoring" {
  description = "Create the PreProd CloudWatch log group and give the existing EC2 role the agent and Grafana permissions."
  type        = bool
  default     = false
}

locals {
  monitoring_stream_names = [
    "cardano-node",
    "cardano-db-sync",
    "midnight-node",
    "midnight-indexer",
    "postgresql",
  ]
}

resource "aws_cloudwatch_log_group" "monitoring" {
  count = var.enable_cloudwatch_monitoring ? 1 : 0

  name              = "/midnight/preprod/host"
  log_group_class   = "STANDARD"
  retention_in_days = 7

  tags = { Name = "${local.name}-host-logs" }
}

resource "aws_iam_role_policy" "monitoring" {
  count = var.enable_cloudwatch_monitoring ? 1 : 0

  name = "${local.name}-cloudwatch-monitoring"
  role = aws_iam_role.node.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishHostLogStreams"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          for stream in local.monitoring_stream_names :
          "${aws_cloudwatch_log_group.monitoring[0].arn}:log-stream:${stream}"
        ]
      },
      {
        Sid    = "ReadHostLogStreams"
        Effect = "Allow"
        Action = ["logs:GetLogEvents"]
        Resource = [
          for stream in local.monitoring_stream_names :
          "${aws_cloudwatch_log_group.monitoring[0].arn}:log-stream:${stream}"
        ]
      },
      {
        Sid      = "QueryHostLogs"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:GetLogGroupFields", "logs:GetLogRecord", "logs:StartQuery", "logs:GetQueryResults"]
        Resource = aws_cloudwatch_log_group.monitoring[0].arn
      },
      {
        Sid      = "DiscoverRegionalMetricsAndLogs"
        Effect   = "Allow"
        Action   = ["cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "logs:DescribeLogGroups", "logs:StopQuery"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
    ]
  })
}

output "cloudwatch_monitoring_log_group" {
  description = "CloudWatch Logs group for the EC2 assessment host when monitoring is enabled."
  value       = one(aws_cloudwatch_log_group.monitoring[*].name)
}
