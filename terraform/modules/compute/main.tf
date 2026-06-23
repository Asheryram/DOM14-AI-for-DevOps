# ── Latest Ubuntu 24.04 LTS AMI ──────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
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

# Download wheels locally then upload to S3 — re-runs only when requirements.txt changes
resource "null_resource" "pip_wheels" {
  triggers = {
    requirements = filemd5("${path.module}/../../../app/requirements.txt")
    bucket       = aws_s3_bucket.packages.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -e
      rm -rf /tmp/ts_wheels && mkdir /tmp/ts_wheels
      pip3 download \
        --platform manylinux2014_x86_64 \
        --python-version 311 \
        --implementation cp \
        --only-binary=:all: \
        flask "prometheus-flask-exporter" prometheus-client \
        requests boto3 psutil gunicorn \
        -d /tmp/ts_wheels
      aws s3 sync /tmp/ts_wheels/ "s3://${aws_s3_bucket.packages.id}/wheels/" \
        --region ${var.aws_region}
    EOT
  }

  depends_on = [aws_s3_bucket.packages, aws_s3_bucket_public_access_block.packages]
}

# ── Security group for app instances ─────────────────────────────────────────

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-App"
  description = "TechStream app instances - Prometheus scrape and outbound"
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
    aws_region      = var.aws_region
    name_prefix     = var.name_prefix
    app_py_b64      = base64encode(file("${path.module}/../../../app/app.py"))
    packages_bucket = aws_s3_bucket.packages.id
  }))
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-App-"
  image_id      = data.aws_ami.ubuntu.id
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
    http_put_response_hop_limit = 2
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
    replace_triggered_by  = [null_resource.pip_wheels]
  }
}
