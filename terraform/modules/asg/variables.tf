variable "name" {
  description = "Name of the Auto Scaling Group"
  type        = string
}

variable "launch_template_id" {
  description = "ID of the EC2 launch template"
  type        = string
}

variable "launch_template_version" {
  description = "Launch template version to run (pass the latest version so changes trigger an instance refresh)"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the ASG"
  type        = list(string)
}

variable "min_size" {
  description = "Minimum number of instances"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of instances"
  type        = number
  default     = 10
}

variable "desired_capacity" {
  description = "Desired number of instances"
  type        = number
  default     = 2
}

variable "health_check_grace_period" {
  description = "Seconds after instance launch before health checks begin"
  type        = number
  default     = 120
}

variable "cpu_target_value" {
  description = "Target average CPU percent for the ASG target-tracking scaling policy (scales out/in to hold this)"
  type        = number
  default     = 75
}
