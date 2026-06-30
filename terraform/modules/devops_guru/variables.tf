variable "app_boundary_key" {
  description = "DevOps Guru tag-based resource boundary key (must start with 'Devops-guru-')"
  type        = string
}

variable "tag_value" {
  description = "Value of the app boundary tag to scope DevOps Guru analysis to"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for DevOps Guru insight notifications"
  type        = string
}
