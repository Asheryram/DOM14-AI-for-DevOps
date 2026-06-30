variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_id" {
  description = "VPC ID for security groups"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — allows Prometheus port from within the VPC"
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Grafana UI on port 3000 (e.g. your public IP as a /32). Prometheus :9090 stays VPC-internal regardless."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "Provide at least one CIDR (e.g. [\"203.0.113.5/32\"]) — leaving Grafana open to the world is not allowed."
  }
}

variable "subnet_id" {
  description = "Public subnet ID for the monitoring EC2 instance"
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling Group name — used for Prometheus EC2 service discovery"
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin user password"
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type for the monitoring server"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access — leave empty to disable SSH"
  type        = string
  default     = ""
}
