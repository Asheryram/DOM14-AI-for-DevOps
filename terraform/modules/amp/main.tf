resource "aws_prometheus_workspace" "this" {
  alias = var.name_prefix
}

# SSM parameter so EC2 user-data scripts can discover the remote_write URL at boot
resource "aws_ssm_parameter" "remote_write_url" {
  name  = "/${var.name_prefix}/amp/remote-write-url"
  type  = "String"
  value = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

# IAM policy to attach to EC2 instance profiles (Prometheus → AMP)
data "aws_iam_policy_document" "remote_write" {
  statement {
    sid       = "AMPRemoteWrite"
    actions   = ["aps:RemoteWrite"]
    resources = [aws_prometheus_workspace.this.arn]
  }
}

resource "aws_iam_policy" "remote_write" {
  name        = "${var.name_prefix}-PrometheusRemoteWritePolicy"
  description = "Attach to EC2 instance profiles so Prometheus can remote_write to AMP"
  policy      = data.aws_iam_policy_document.remote_write.json
}
