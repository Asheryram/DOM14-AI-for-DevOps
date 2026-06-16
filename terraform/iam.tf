data "aws_iam_policy_document" "remediator" {
  statement {
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:SetDesiredCapacity"
    ]
    resources = ["*"]
  }

  statement {
    actions = ["ssm:SendCommand","ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    actions = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    actions = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:log-group:/techstream/remediation-events*"]
  }

  statement {
    actions = ["ses:SendEmail","ses:SendRawEmail"]
    resources = ["arn:aws:ses:us-east-1:*:identity/techstream.io"]
  }
}

resource "aws_iam_policy" "remediator_policy" {
  name   = "TechStreamRemediatorPolicy"
  policy = data.aws_iam_policy_document.remediator.json
}
