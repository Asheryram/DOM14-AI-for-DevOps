resource "aws_sns_topic" "alerts" {
  name = "techstream-alerts"
}

resource "aws_sns_topic_subscription" "oncall" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "oncall@techstream.io"
}

resource "aws_sns_topic_subscription" "incidents" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "incidents@techstream.io"
}

resource "null_resource" "confirm_sns" {
  provisioner "local-exec" {
    command = "echo 'ACTION REQUIRED: Confirm SNS email subscriptions before testing.'"
  }
}
