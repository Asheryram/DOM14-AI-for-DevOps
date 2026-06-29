variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
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

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across (multi-AZ assumed)"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2 — the ASG and VPC endpoints assume multi-AZ."
  }
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

  validation {
    condition     = var.asg_desired_capacity >= var.asg_min_size && var.asg_desired_capacity <= var.asg_max_size
    error_message = "asg_desired_capacity must be between asg_min_size and asg_max_size."
  }
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
  default     = "anthropic.claude-sonnet-4-6"
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
