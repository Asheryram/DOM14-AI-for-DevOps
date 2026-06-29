output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (monitoring EC2 — Prometheus + Grafana)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (app ASG instances — no internet route)"
  value       = aws_subnet.private[*].id
}

output "cidr_block" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}
