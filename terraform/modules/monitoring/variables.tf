variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC ID for security groups"
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet IDs (≥2 AZs) for the ALB and ECS Fargate tasks"
  type        = list(string)
}

variable "amp_endpoint" {
  description = "AMP workspace prometheus_endpoint (base URL)"
  type        = string
}

variable "amp_workspace_arn" {
  description = "AMP workspace ARN (scopes Grafana task role permissions)"
  type        = string
}

variable "alerts_sns_topic_arn" {
  description = "SNS topic ARN wired as a Grafana alert notification channel"
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin user password"
  type        = string
  sensitive   = true
}

variable "grafana_image_uri" {
  description = "ECR image URI for the custom Grafana image. Defaults to <ecr_repo>:latest if empty."
  type        = string
  default     = ""
}

variable "grafana_task_cpu" {
  description = "Fargate task CPU units (512 = 0.5 vCPU)"
  type        = number
  default     = 512
}

variable "grafana_task_memory" {
  description = "Fargate task memory in MiB"
  type        = number
  default     = 1024
}
