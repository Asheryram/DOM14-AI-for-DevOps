resource "aws_autoscaling_group" "this" {
  name                = var.name
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = var.launch_template_id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period
  wait_for_capacity_timeout = "10m"

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "TechStream-App"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
