output "grafana_url" {
  description = "Grafana dashboard URL — open in browser (admin / grafana_admin_password)"
  value       = module.monitoring.grafana_url
}

output "prometheus_url" {
  description = "Prometheus URL — for ad-hoc PromQL queries"
  value       = module.monitoring.prometheus_url
}

output "monitoring_instance_id" {
  description = "Monitoring EC2 instance ID (Prometheus + Grafana)"
  value       = module.monitoring.instance_id
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = module.asg.name
}

output "sns_topic_arn" {
  description = "SNS alerts topic ARN"
  value       = module.alarms.sns_topic_arn
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
  description = "Public subnet IDs (monitoring EC2)"
  value       = module.vpc.public_subnet_ids
}
