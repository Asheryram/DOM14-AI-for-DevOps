variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the instance security group"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used to allow intra-VPC Prometheus scraping"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the app"
  type        = string
  default     = "t3.medium"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access — leave empty to disable SSH"
  type        = string
  default     = ""
}

variable "ec2_remote_write_policy_arn" {
  description = "ARN of the IAM policy that allows Prometheus to remote_write to AMP"
  type        = string
}

variable "amp_ssm_parameter_name" {
  description = "SSM parameter name that holds the AMP remote_write URL"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
