locals {
  user_data = base64encode(templatefile("${path.module}/monitoring_user_data.sh.tpl", {
    aws_region             = var.aws_region
    asg_name               = var.asg_name
    grafana_admin_password = var.grafana_admin_password
    dashboard_json_b64     = base64encode(file("${path.module}/../../../monitoring/grafana/dashboards/techstream_golden_signals.json"))
  }))
}

# ── Latest Amazon Linux 2023 AMI ──────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM role for Prometheus EC2 service discovery ─────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.name_prefix}-MonitoringInstanceRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_sd" {
  statement {
    sid = "PrometheusEC2SD"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_sd" {
  name   = "PrometheusEC2ServiceDiscovery"
  role   = aws_iam_role.monitoring.id
  policy = data.aws_iam_policy_document.ec2_sd.json
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.name_prefix}-MonitoringInstanceProfile"
  role = aws_iam_role.monitoring.name
}

# ── Security group ────────────────────────────────────────────────────────────

resource "aws_security_group" "monitoring" {
  name        = "${var.name_prefix}-Monitoring"
  description = "Grafana (public) and Prometheus (VPC-internal)"
  vpc_id      = var.vpc_id

  ingress {
    description = "Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus UI (VPC only)"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # SSH is intentionally not opened — the instance is managed via SSM Session
  # Manager (AmazonSSMManagedInstanceCore is attached). This avoids exposing
  # port 22 on a public host. Use `aws ssm start-session` for shell access.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name
  key_name                    = var.key_name != "" ? var.key_name : null
  user_data_base64            = local.user_data
  associate_public_ip_address = true # needed at first boot to fetch Prometheus/Grafana before the EIP attaches

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.name_prefix}-Monitoring"
    Role = "TechStream-Monitoring"
  }
}

# ── Elastic IP (stable Grafana URL that survives stop/start) ──────────────────

resource "aws_eip" "monitoring" {
  instance = aws_instance.monitoring.id
  domain   = "vpc"

  tags = {
    Name = "${var.name_prefix}-Monitoring-EIP"
  }
}
