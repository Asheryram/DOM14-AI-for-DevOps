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

# CPU saturation is handled here — declaratively — not by the remediator Lambda.
# Target tracking keeps the fleet's average CPU near the target, scaling OUT under
# load and back IN when it subsides (between min_size and max_size). This is what
# auto-scaling is for; the Lambda is reserved for what scaling can't do (restart a
# wedged/leaking service on the ErrorRate/Memory alarms).
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${var.name}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_value
  }
}
