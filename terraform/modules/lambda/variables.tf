variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "asg_name" {
  description = "Name of the Auto Scaling Group the remediator controls"
  type        = string
}

variable "alerts_sns_topic_arn" {
  description = "ARN of the SNS topic that triggers the remediator Lambda"
  type        = string
}

variable "ses_from" {
  description = "Verified SES sender address"
  type        = string
}

variable "ses_to" {
  description = "Destination email for automated notifications"
  type        = string
}

variable "oncall" {
  description = "On-call email address (Cc on RCA emails)"
  type        = string
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID for RCA summarisation"
  type        = string
}

variable "remediator_zip" {
  description = "Path to the remediator Lambda deployment package"
  type        = string
}

variable "remediator_zip_hash" {
  description = "Base64-encoded SHA256 of the remediator zip (triggers updates)"
  type        = string
}

variable "rca_summariser_zip" {
  description = "Path to the RCA summariser Lambda deployment package"
  type        = string
}

variable "rca_summariser_zip_hash" {
  description = "Base64-encoded SHA256 of the RCA summariser zip (triggers updates)"
  type        = string
}

variable "aws_region" {
  description = "AWS region (passed to Lambda as AWS_REGION env var)"
  type        = string
  default     = "eu-west-1"
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 60
}

variable "lambda_memory" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 256
}
