resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "oncall" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.oncall_email
}

resource "aws_sns_topic_subscription" "incidents" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.incidents_email
}

resource "null_resource" "confirm_subscriptions" {
  provisioner "local-exec" {
    command = "echo 'ACTION REQUIRED: confirm SNS email subscriptions for ${var.oncall_email} and ${var.incidents_email}'"
  }
}

resource "aws_cloudwatch_metric_alarm" "error_rate_high" {
  alarm_name          = "${var.name_prefix}-ErrorRate-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 120
  statistic           = "Average"
  threshold           = var.error_rate_threshold
  metric_name         = "5xx_error_rate"
  namespace           = "TechStream/GoldenSignals"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  treat_missing_data        = "breaching"
  alarm_description         = "5xx error rate exceeded ${var.error_rate_threshold}% for 2 consecutive 2-minute periods"
  alarm_actions             = [aws_sns_topic.alerts.arn]
  ok_actions                = [aws_sns_topic.alerts.arn]
  insufficient_data_actions = []
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name_prefix}-CPU-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_threshold
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  treat_missing_data        = "missing"
  alarm_description         = "Average CPU exceeded ${var.cpu_threshold}% for 3 consecutive minutes"
  alarm_actions             = [aws_sns_topic.alerts.arn]
  ok_actions                = [aws_sns_topic.alerts.arn]
  insufficient_data_actions = []
}

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.name_prefix}-Memory-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 60
  statistic           = "Average"
  threshold           = var.memory_threshold
  metric_name         = "mem_used_percent"
  namespace           = "TechStream/GoldenSignals"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  treat_missing_data        = "breaching"
  alarm_description         = "Memory usage exceeded ${var.memory_threshold}% for 2 consecutive minutes"
  alarm_actions             = [aws_sns_topic.alerts.arn]
  ok_actions                = [aws_sns_topic.alerts.arn]
  insufficient_data_actions = []
}
