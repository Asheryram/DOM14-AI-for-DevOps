resource "aws_devopsguru_resource_collection" "this" {
  type = "AWS_CLOUD_FORMATION"

  cloud_formation {
    stack_names = [var.stack_name]
  }
}

resource "aws_devopsguru_notification_channel" "this" {
  sns {
    topic_arn = var.sns_topic_arn
  }
}
