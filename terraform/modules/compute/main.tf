# ── Latest Amazon Linux 2023 AMI (standard, NOT minimal) ──────────────────────
# AL2023 is required for the no-NAT private-subnet design: its dnf repos are
# served from in-region S3 (reachable via the S3 gateway endpoint) and the SSM
# agent is preinstalled, so instances need no internet path to bootstrap.
# The pattern excludes the "al2023-ami-minimal-*" variant, which ships WITHOUT
# the SSM agent and would leave instances unmanageable (PingStatus: Offline).

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

# ── S3 bucket for pre-staged Python wheels ────────────────────────────────────

resource "aws_s3_bucket" "packages" {
  bucket        = "${lower(replace(var.name_prefix, "_", "-"))}-pkg-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.name_prefix}-Packages" }
}

resource "aws_s3_bucket_public_access_block" "packages" {
  bucket = aws_s3_bucket.packages.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "packages" {
  bucket = aws_s3_bucket.packages.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Stage offline artifacts to S3 so the private app instances (no NAT, no internet)
# can install everything via the S3 gateway endpoint:
#   - Python wheels built for the instance interpreter (cp311 / manylinux2014)
#   - node_exporter binary for host CPU/memory metrics scraped by Prometheus
# Re-runs only when requirements.txt or the node_exporter version changes.
resource "null_resource" "stage_artifacts" {
  triggers = {
    requirements          = filemd5("${path.module}/../../../app/requirements.txt")
    node_exporter_version = var.node_exporter_version
    bucket                = aws_s3_bucket.packages.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      rm -rf /tmp/ts_wheels && mkdir -p /tmp/ts_wheels

      # Python wheels — built for the instance interpreter (Python 3.11 on AL2023),
      # NOT the local machine's Python. Pure-python deps download as universal wheels.
      pip3 download \
        --platform manylinux2014_x86_64 \
        --python-version 311 \
        --implementation cp \
        --only-binary=:all: \
        -r "${path.module}/../../../app/requirements.txt" \
        -d /tmp/ts_wheels
      aws s3 sync /tmp/ts_wheels/ "s3://${aws_s3_bucket.packages.id}/wheels/" \
        --region ${var.aws_region} --delete

      # node_exporter binary
      NE="node_exporter-${var.node_exporter_version}.linux-amd64"
      curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${var.node_exporter_version}/$${NE}.tar.gz" \
        -o "/tmp/$${NE}.tar.gz"
      aws s3 cp "/tmp/$${NE}.tar.gz" "s3://${aws_s3_bucket.packages.id}/node_exporter/$${NE}.tar.gz" \
        --region ${var.aws_region}
    EOT
  }

  depends_on = [aws_s3_bucket.packages, aws_s3_bucket_public_access_block.packages]
}

# ── Security group for app instances ─────────────────────────────────────────

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-App"
  description = "TechStream app instances - in-VPC metrics scrape and outbound only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Flask app + /metrics scrape from within VPC"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "node_exporter host metrics scrape from within VPC"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
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

data "aws_iam_policy_document" "s3_packages" {
  statement {
    sid     = "ReadPackagesBucket"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.packages.arn,
      "${aws_s3_bucket.packages.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "s3_packages" {
  name   = "ReadPackagesBucket"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.s3_packages.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name_prefix}-AppInstanceProfile"
  role = aws_iam_role.app.name
}

# ── Launch template ───────────────────────────────────────────────────────────

locals {
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    aws_region            = var.aws_region
    name_prefix           = var.name_prefix
    app_py_b64            = base64encode(file("${path.module}/../../../app/app.py"))
    packages_bucket       = aws_s3_bucket.packages.id
    node_exporter_version = var.node_exporter_version
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

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
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
    replace_triggered_by  = [null_resource.stage_artifacts]
  }
}
