variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev)"
  type        = string
  default     = "prod"
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC Terraform creates"
  type        = string
  default     = "10.0.0.0/16"
}

# ── Compute ───────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = "EC2 instance type for TechStream app instances"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access — leave empty to disable SSH"
  type        = string
  default     = ""
}

# ── Auto Scaling ──────────────────────────────────────────────────────────────

variable "asg_min_size" {
  description = "Minimum number of instances in the ASG"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances in the ASG"
  type        = number
  default     = 10
}

variable "asg_desired_capacity" {
  description = "Initial desired capacity of the ASG"
  type        = number
  default     = 2
}

# ── Notifications ─────────────────────────────────────────────────────────────

variable "oncall_email" {
  description = "On-call email address for SNS alert subscriptions"
  type        = string
  default     = "oncall@techstream.io"
}

variable "incidents_email" {
  description = "Incidents team email for SNS subscriptions and Lambda notifications"
  type        = string
  default     = "incidents@techstream.io"
}

variable "ses_from_email" {
  description = "Verified SES sender address for automated emails"
  type        = string
  default     = "devops-guru@techstream.io"
}

# ── AI / Bedrock ──────────────────────────────────────────────────────────────

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID for RCA summarisation"
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6-20251001-v1:0"
}

# ── DevOps Guru ───────────────────────────────────────────────────────────────

variable "cloudformation_stack_name" {
  description = "CloudFormation stack name for DevOps Guru to monitor"
  type        = string
  default     = "TechStream-Prod"
}

# ── Grafana ───────────────────────────────────────────────────────────────────

variable "grafana_admin_password" {
  description = "Grafana admin password — store in terraform.tfvars, never commit"
  type        = string
  sensitive   = true
}
