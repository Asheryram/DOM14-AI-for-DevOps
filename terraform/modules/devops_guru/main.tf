# Tag-based resource boundary — this stack is built with Terraform, not
# CloudFormation, so DevOps Guru is scoped by the "Devops-guru-*" app boundary
# tag that the provider default_tags apply to every resource.
resource "aws_devopsguru_resource_collection" "this" {
  type = "AWS_TAGS"

  tags {
    app_boundary_key = var.app_boundary_key
    tag_values       = [var.tag_value]
  }
}

resource "aws_devopsguru_notification_channel" "this" {
  sns {
    topic_arn = var.sns_topic_arn
  }
}
