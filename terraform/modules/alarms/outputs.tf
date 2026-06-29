output "sns_topic_arn" {
  description = "ARN of the alerts SNS topic (CloudWatch alarm/OK notifications + email)"
  value       = aws_sns_topic.alerts.arn
}

output "insights_topic_arn" {
  description = "ARN of the DevOps Guru insights SNS topic (RCA summariser only)"
  value       = aws_sns_topic.insights.arn
}

output "error_rate_alarm_arn" {
  description = "ARN of the 5xx error rate alarm"
  value       = aws_cloudwatch_metric_alarm.error_rate_high.arn
}

output "cpu_alarm_arn" {
  description = "ARN of the CPU high alarm"
  value       = aws_cloudwatch_metric_alarm.cpu_high.arn
}

output "memory_alarm_arn" {
  description = "ARN of the memory high alarm"
  value       = aws_cloudwatch_metric_alarm.memory_high.arn
}
