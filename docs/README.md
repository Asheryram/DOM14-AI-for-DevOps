# DOM14 AI for DevOps

This repository contains a self-healing TechStream demo system with:

- A Python Flask ingest app instrumented with Prometheus metrics
- Monitoring configuration for Prometheus / Grafana / CloudWatch
- Chaos injection tools for HTTP 500, CPU saturation, and memory leak scenarios
- AWS Terraform stubs for CloudWatch alarming, SNS, IAM policy, and DevOps Guru
- Lambda remediation and RCA summariser skeletons
- Verification and insight parsing scripts

## Root structure

- `app.py` — Flask app with Prometheus instrumentation
- `requirements.txt` — Python dependencies
- `prometheus.yml` — Prometheus scrape config
- `grafana_dashboard.json` — Grafana dashboard stub
- `cloudwatch-agent.json` — CloudWatch agent config
- `chaos.py` — chaos injection runner
- `remediator.py` — Lambda remediation logic
- `rca_summariser.py` — Lambda RCA summariser logic
- `parse_insight.py` — DevOps Guru insight parsing helper
- `verify_healing.sh` — end-to-end verification scaffold
- `terraform/` — grouped Terraform modules and resources
- `docs/` — project documentation

## Getting started

1. Install dependencies:

```bash
python -m pip install -r requirements.txt
```

2. Run the app locally:

```bash
python app.py
```

3. Run a basic chaos test against a local app:

```bash
python chaos.py --scenario http_500 --alb-dns localhost:8000 --region us-east-1
```

## Terraform layout

Terraform files are grouped under `terraform/`:

- `main.tf` — AWS provider and ASG placeholder
- `cloudwatch.tf` — CloudWatch alarm
- `sns.tf` — SNS topic and email subscriptions
- `iam.tf` — Lambda IAM policy
- `devops_guru.tf` — DevOps Guru resource collection

## Notes

- `grafana_dashboard.json` is a stub and should be replaced with a full dashboard export.
- AWS resources are placeholders; complete configuration and actual ARNs are needed before deployment.
- SES requires verified identities in sandbox mode.
