resource "aws_autoscaling_group" "this" {
  name                = var.name
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id = var.launch_template_id
    # Pin to the explicit latest version (not the "$Latest" literal) so a
    # launch-template change produces a real diff here and drives instance_refresh.
    version = var.launch_template_version
  }

  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period
  wait_for_capacity_timeout = "10m"

  # Roll the fleet when the launch template changes (e.g. new app code or
  # updated dependencies staged to S3) so running instances pick up the change.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = var.health_check_grace_period
    }
    triggers = ["launch_template"]
  }

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
