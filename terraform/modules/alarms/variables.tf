variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "asg_name" {
  description = "Name of the Auto Scaling Group (used as alarm dimension)"
  type        = string
}

variable "oncall_email" {
  description = "On-call email for SNS subscription"
  type        = string
}

variable "incidents_email" {
  description = "Incidents team email for SNS subscription"
  type        = string
}

variable "error_rate_threshold" {
  description = "5xx error rate (%) that triggers the alarm"
  type        = number
  default     = 5
}

variable "cpu_threshold" {
  description = "CPU utilisation (%) that triggers the alarm"
  type        = number
  default     = 85
}

variable "memory_threshold" {
  description = "Memory usage (%) that triggers the alarm"
  type        = number
  default     = 90
}
