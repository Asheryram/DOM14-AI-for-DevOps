output "grafana_url" {
  description = "Grafana URL — open in browser (admin / grafana_admin_password)"
  value       = "http://${aws_eip.monitoring.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus URL — for ad-hoc PromQL queries"
  value       = "http://${aws_eip.monitoring.public_ip}:9090"
}

output "instance_id" {
  description = "Monitoring EC2 instance ID"
  value       = aws_instance.monitoring.id
}
