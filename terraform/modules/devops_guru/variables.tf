variable "stack_name" {
  description = "CloudFormation stack name for DevOps Guru to monitor"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for DevOps Guru insight notifications"
  type        = string
}
