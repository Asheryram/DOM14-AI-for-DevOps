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
