provider "aws" {
  region = "us-east-1"
}

resource "aws_autoscaling_group" "prod" {
  name = "TechStream-Prod-ASG"
  # ASG details (AMI, launch template, subnets) should be filled in by the operator
}
