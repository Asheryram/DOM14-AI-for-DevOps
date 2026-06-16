resource "aws_cloudwatch_metric_alarm" "error_rate_high" {
  alarm_name          = "TechStream-ErrorRate-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 120
  threshold           = 5
  metric_name         = "5xx_error_rate"
  namespace           = "TechStream/GoldenSignals"
  treat_missing_data  = "breaching"
  alarm_description   = "Alarm when 5xx error rate > 5%"
}
