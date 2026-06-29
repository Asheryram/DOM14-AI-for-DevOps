output "launch_template_id" {
  description = "EC2 launch template ID"
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template (drives ASG instance refresh on change)"
  value       = aws_launch_template.app.latest_version
}

output "instance_profile_arn" {
  description = "IAM instance profile ARN"
  value       = aws_iam_instance_profile.app.arn
}

output "security_group_id" {
  description = "App instance security group ID"
  value       = aws_security_group.app.id
}

output "ami_id" {
  description = "Amazon Linux 2023 AMI used in the launch template"
  value       = data.aws_ami.al2023.id
}
