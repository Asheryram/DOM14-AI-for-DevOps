# ── IAM ──────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-LambdaRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid     = "ASG"
    actions = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:SetDesiredCapacity"]
    resources = ["*"]
  }

  statement {
    sid     = "SSM"
    actions = ["ssm:SendCommand", "ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid     = "CloudWatch"
    actions = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/techstream/*"
    ]
  }

  statement {
    sid     = "SES"
    actions = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["arn:aws:ses:${var.aws_region}:*:identity/*"]
  }

  statement {
    sid     = "Bedrock"
    actions = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.aws_region}::foundation-model/*"]
  }
}

resource "aws_iam_policy" "this" {
  name        = "${var.name_prefix}-LambdaPolicy"
  description = "Permissions for TechStream remediation and RCA Lambda functions"
  policy      = data.aws_iam_policy_document.permissions.json
}

resource "aws_iam_role_policy_attachment" "custom" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

# ── Remediator Lambda ─────────────────────────────────────────────────────────

resource "aws_lambda_function" "remediator" {
  function_name    = "${var.name_prefix}-Remediator"
  filename         = var.remediator_zip
  source_code_hash = var.remediator_zip_hash
  handler          = "handler.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.this.arn
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory

  environment {
    variables = {
      ASG_NAME = var.asg_name
      SES_FROM = var.ses_from
      SES_TO   = var.ses_to
    }
  }

  depends_on = [aws_iam_role_policy_attachment.basic_execution]
}

resource "aws_lambda_permission" "remediator_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediator.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.alerts_sns_topic_arn
}

resource "aws_sns_topic_subscription" "remediator" {
  topic_arn = var.alerts_sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.remediator.arn
}

# ── EventBridge rule: CloudWatch Alarm → Remediator Lambda ───────────────────
# This is the primary remediation trigger the project objectives call for.
# The SNS subscription above remains as a fallback notification path.

resource "aws_cloudwatch_event_rule" "alarm_to_remediation" {
  name        = "${var.name_prefix}-AlarmToRemediation"
  description = "Routes CloudWatch ALARM state changes to the remediator Lambda"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      state = { value = ["ALARM"] }
      alarmName = [
        "${var.name_prefix}-ErrorRate-High",
        "${var.name_prefix}-CPU-High",
        "${var.name_prefix}-Memory-High"
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "remediator" {
  rule      = aws_cloudwatch_event_rule.alarm_to_remediation.name
  target_id = "RemediatorLambda"
  arn       = aws_lambda_function.remediator.arn
}

resource "aws_lambda_permission" "remediator_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_to_remediation.arn
}

# ── RCA Summariser Lambda ─────────────────────────────────────────────────────

resource "aws_lambda_function" "rca_summariser" {
  function_name    = "${var.name_prefix}-RCASummariser"
  filename         = var.rca_summariser_zip
  source_code_hash = var.rca_summariser_zip_hash
  handler          = "handler.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.this.arn
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory

  environment {
    variables = {
      BEDROCK_MODEL = var.bedrock_model_id
      SES_FROM      = var.ses_from
      SES_TO        = var.ses_to
      ONCALL        = var.oncall
    }
  }

  depends_on = [aws_iam_role_policy_attachment.basic_execution]
}

resource "aws_lambda_permission" "rca_summariser_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rca_summariser.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.alerts_sns_topic_arn
}

resource "aws_sns_topic_subscription" "rca_summariser" {
  topic_arn = var.alerts_sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.rca_summariser.arn
}

# ── CloudWatch Log Groups (explicit retention) ────────────────────────────────

resource "aws_cloudwatch_log_group" "remediator" {
  name              = "/aws/lambda/${aws_lambda_function.remediator.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "rca_summariser" {
  name              = "/aws/lambda/${aws_lambda_function.rca_summariser.function_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "remediation_events" {
  name              = "/techstream/remediation-events"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "chaos_events" {
  name              = "/techstream/chaos-events"
  retention_in_days = 14
}
