output "grafana_url" {
  description = "Grafana URL — open in browser (admin / your grafana_admin_password)"
  value       = "http://${aws_lb.grafana.dns_name}"
}

output "ecr_repository_url" {
  description = "ECR repo — build and push the Grafana image here before ECS starts"
  value       = aws_ecr_repository.grafana.repository_url
}
