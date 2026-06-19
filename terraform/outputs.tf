output "grafana_url" {
  description = "Grafana dashboard URL — open in browser (admin / grafana_admin_password)"
  value       = module.monitoring.grafana_url
}

output "ecr_repository_url" {
  description = "Push the custom Grafana image here before the ECS service starts"
  value       = module.monitoring.ecr_repository_url
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = module.asg.name
}

output "sns_topic_arn" {
  description = "SNS alerts topic ARN"
  value       = module.alarms.sns_topic_arn
}

output "amp_remote_write_url" {
  description = "Paste into prometheus.yml remote_write.url on EC2 Prometheus instances"
  value       = module.amp.remote_write_url
}

output "amp_ssm_parameter" {
  description = "SSM parameter that stores the AMP remote_write URL (EC2 user-data reads this)"
  value       = module.amp.ssm_parameter_name
}

output "remediator_function_arn" {
  description = "Remediator Lambda ARN"
  value       = module.lambda.remediator_function_arn
}

output "rca_summariser_function_arn" {
  description = "RCA summariser Lambda ARN"
  value       = module.lambda.rca_summariser_function_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (app ASG)"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, Grafana ECS)"
  value       = module.vpc.public_subnet_ids
}
