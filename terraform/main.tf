locals {
  name_prefix = "TechStream-${var.environment}"
}

# ── Networking ────────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  name_prefix = local.name_prefix
  cidr_block  = var.vpc_cidr
}

# ── Amazon Managed Service for Prometheus ─────────────────────────────────────

module "amp" {
  source = "./modules/amp"

  name_prefix = local.name_prefix
}

# ── EC2 launch template + instance profile ────────────────────────────────────

module "compute" {
  source = "./modules/compute"

  name_prefix                 = local.name_prefix
  vpc_id                      = module.vpc.vpc_id
  vpc_cidr                    = module.vpc.cidr_block
  instance_type               = var.instance_type
  key_name                    = var.key_name
  ec2_remote_write_policy_arn = module.amp.ec2_remote_write_policy_arn
  amp_ssm_parameter_name      = module.amp.ssm_parameter_name
  aws_region                  = var.aws_region
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────

module "asg" {
  source = "./modules/asg"

  name                      = "${local.name_prefix}-ASG"
  launch_template_id        = module.compute.launch_template_id
  subnet_ids                = module.vpc.private_subnet_ids
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  health_check_grace_period = 120
}

# ── CloudWatch alarms + SNS alerts topic ──────────────────────────────────────

module "alarms" {
  source = "./modules/alarms"

  name_prefix     = local.name_prefix
  asg_name        = module.asg.name
  oncall_email    = var.oncall_email
  incidents_email = var.incidents_email
}

# ── Lambda functions (remediator + RCA summariser) ────────────────────────────

data "archive_file" "remediator" {
  type        = "zip"
  source_file = "${path.module}/../lambda/remediator/handler.py"
  output_path = "${path.module}/../.build/remediator.zip"
}

data "archive_file" "rca_summariser" {
  type        = "zip"
  source_file = "${path.module}/../lambda/rca_summariser/handler.py"
  output_path = "${path.module}/../.build/rca_summariser.zip"
}

module "lambda" {
  source = "./modules/lambda"

  name_prefix             = local.name_prefix
  asg_name                = module.asg.name
  alerts_sns_topic_arn    = module.alarms.sns_topic_arn
  ses_from                = var.ses_from_email
  ses_to                  = var.incidents_email
  oncall                  = var.oncall_email
  bedrock_model_id        = var.bedrock_model_id
  remediator_zip          = data.archive_file.remediator.output_path
  remediator_zip_hash     = data.archive_file.remediator.output_base64sha256
  rca_summariser_zip      = data.archive_file.rca_summariser.output_path
  rca_summariser_zip_hash = data.archive_file.rca_summariser.output_base64sha256
  aws_region              = var.aws_region
}

# ── DevOps Guru ───────────────────────────────────────────────────────────────

module "devops_guru" {
  source = "./modules/devops_guru"

  stack_name    = var.cloudformation_stack_name
  sns_topic_arn = module.alarms.sns_topic_arn
}

# ── Grafana on ECS Fargate ────────────────────────────────────────────────────

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix            = local.name_prefix
  aws_region             = var.aws_region
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.public_subnet_ids
  amp_endpoint           = module.amp.prometheus_endpoint
  amp_workspace_arn      = module.amp.workspace_arn
  alerts_sns_topic_arn   = module.alarms.sns_topic_arn
  grafana_admin_password = var.grafana_admin_password
}
