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
  description = "EC2 key pair name. App instances are private (SSM-only); this is reserved for break-glass and is intentionally NOT wired to an inbound SSH rule."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "node_exporter_version" {
  description = "node_exporter version to stage to S3 and run on app instances for host CPU/memory metrics"
  type        = string
  default     = "1.8.2"
}
