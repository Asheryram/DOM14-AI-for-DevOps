# ── Latest Amazon Linux 2023 AMI ──────────────────────────────────────────────

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security group for app instances ─────────────────────────────────────────

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-App"
  description = "TechStream app instances — Prometheus scrape + outbound only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Prometheus metrics scrape from within VPC"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  dynamic "ingress" {
    for_each = var.key_name != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── IAM role + instance profile ───────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name_prefix}-AppInstanceRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "amp_remote_write" {
  role       = aws_iam_role.app.name
  policy_arn = var.ec2_remote_write_policy_arn
}

data "aws_iam_policy_document" "ssm_read" {
  statement {
    sid     = "ReadAMPParam"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:*:parameter${var.amp_ssm_parameter_name}"
    ]
  }
}

resource "aws_iam_role_policy" "ssm_read" {
  name   = "ReadAMPSSMParam"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.ssm_read.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-AppInstanceProfile"
  role = aws_iam_role.app.name
}

# ── Launch template ───────────────────────────────────────────────────────────

locals {
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    aws_region             = var.aws_region
    amp_ssm_parameter_name = var.amp_ssm_parameter_name
    name_prefix            = var.name_prefix
  }))
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-App-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app.id]
  }

  key_name  = var.key_name != "" ? var.key_name : null
  user_data = local.user_data

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-App"
      Role = "TechStream-App"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
