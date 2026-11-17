output "instance_id" {
  description = "EC2 instance ID used to connect through Session Manager."
  value       = aws_instance.node.id
}

output "availability_zone" {
  description = "Availability Zone shared by the instance and its EBS data volume."
  value       = aws_subnet.public.availability_zone
}

output "ami_id" {
  description = "Ubuntu AMI selected for review."
  value       = local.ami_id
}

output "data_volume_id" {
  description = "Persistent data volume ID. Match this ID to the NVMe device before mounting."
  value       = aws_ebs_volume.data.id
}

output "session_manager_command" {
  description = "Connect to the host once it appears as an online managed node."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.node.id}"
}
