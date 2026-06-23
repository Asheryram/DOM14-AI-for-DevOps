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

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}
