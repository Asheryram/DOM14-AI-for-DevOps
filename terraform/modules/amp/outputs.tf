output "workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.this.id
}

output "workspace_arn" {
  description = "AMP workspace ARN"
  value       = aws_prometheus_workspace.this.arn
}

output "prometheus_endpoint" {
  description = "AMP workspace base endpoint"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "remote_write_url" {
  description = "Full remote_write URL for prometheus.yml"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

output "ssm_parameter_name" {
  description = "SSM parameter name that stores the remote_write URL"
  value       = aws_ssm_parameter.remote_write_url.name
}

output "ec2_remote_write_policy_arn" {
  description = "IAM policy ARN to attach to EC2 instance profiles"
  value       = aws_iam_policy.remote_write.arn
}
