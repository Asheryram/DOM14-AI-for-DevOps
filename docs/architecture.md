# Architecture Overview

The solution is designed around a self-healing pipeline for a Flask-based ingestion service.

## Components

### Flask service (`app.py`)

- Exposes `/api/v1/ingest`, `/api/v1/health`, `/api/v1/status`
- Uses `prometheus_flask_exporter` to expose `/metrics`
- Tracks latency, request count, and error count by endpoint and method
- Simulates realistic processing delay and payload validation

### Monitoring

- `prometheus.yml` configures Prometheus to scrape the Flask service via EC2 service discovery
- `grafana_dashboard.json` is a dashboard stub with latency, traffic, error rate, and saturation panels
- `cloudwatch-agent.json` is a CloudWatch agent config to mirror host CPU metrics into `TechStream/GoldenSignals`

### Chaos Engineering

- `chaos.py` implements three scenarios:
  - `http_500` for 500 error flood
  - `cpu_spike` for CPU saturation
  - `memory_leak` for memory pressure
- Logs start/end events to CloudWatch Logs under `/techstream/chaos-events`

### Automated remediation

- `remediator.py` is a Lambda handler that either scales the ASG or restarts Flask via SSM
- `rca_summariser.py` is a Lambda handler that calls Bedrock for RCA and sends HTML email via SES

### Terraform

Terraform files are grouped under `terraform/` for better organization.

- `terraform/main.tf` — provider and ASG stub
- `terraform/cloudwatch.tf` — alarm definition
- `terraform/sns.tf` — SNS topic and subscriptions
- `terraform/iam.tf` — IAM policy for Lambda remediation
- `terraform/devops_guru.tf` — DevOps Guru resource collection

## Deployment flow

1. Deploy infrastructure with Terraform.
2. Run the Flask app behind ALB / ASG.
3. Enable Prometheus scraping and Grafana dashboards.
4. Trigger chaos scenarios and confirm CloudWatch alarms.
5. Lambda responds and attempts automated remediation.
6. DevOps Guru insight triggers RCA email summarisation.
