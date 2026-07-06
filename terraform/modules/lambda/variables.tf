variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "asg_name" {
  description = "Name of the Auto Scaling Group the remediator controls"
  type        = string
}

variable "insights_sns_topic_arn" {
  description = "ARN of the DevOps Guru insights SNS topic that triggers the RCA summariser Lambda"
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
  description = "AWS region, used to build SES/Bedrock IAM resource ARNs. Not set as a Lambda env var — AWS_REGION is reserved and injected by the runtime; boto3 reads it automatically."
  type        = string
  default     = "eu-west-1"
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds (allows diagnostics capture + SSM restart poll + SES)"
  type        = number
  default     = 120
}

variable "lambda_memory" {
  description = "Lambda function memory in MB"
  type        = number
  default     = 256
}
