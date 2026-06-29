# DOM14 AI for DevOps — TechStream Self-Healing System

A fully automated self-healing pipeline for a Flask data-ingestion service on AWS,
provisioned end to end with Terraform. When the service degrades, the system detects
the anomaly, remediates it automatically, and emails an AI-generated root-cause
analysis — with no human intervention.

## What's in here

- **Flask ingest app** (`app/app.py`) — instrumented with Prometheus metrics and a
  background thread that publishes Golden-Signal metrics (`5xx_error_rate`,
  `mem_used_percent`) to CloudWatch.
- **Self-hosted monitoring** — a single EC2 instance running **Prometheus** (binary,
  port 9090) and **Grafana** (RPM, port 3000). Prometheus uses EC2 service discovery
  to scrape both the app (`:8000`) and `node_exporter` (`:9100`) on every ASG instance.
- **Self-healing remediation** — 3 CloudWatch alarms → an EventBridge rule →
  a Remediator Lambda that either scales the ASG out or restarts the `techstream`
  systemd unit via SSM.
- **AI RCA** — Amazon DevOps Guru insights → a dedicated SNS topic → an RCA Summariser
  Lambda that calls Amazon Bedrock and emails an HTML report via SES.
- **Chaos engineering** (`chaos/`) — three fault-injection scenarios run on an app
  instance via SSM Run Command, plus an end-to-end verification script.
- **Tests + CI** — a pytest suite under `tests/` and a GitHub Actions workflow.

Everything runs in **eu-west-1**. Both the app instances and the monitoring instance
run **Amazon Linux 2023**. There is **no ALB, no NAT gateway, and no Docker** anywhere
in the system.

## Repository structure

- `app/app.py` — Flask ingest API with Prometheus instrumentation
- `app/requirements.txt` — app runtime dependencies
- `lambda/remediator/handler.py` — decides: scale out or SSM-restart the service
- `lambda/rca_summariser/handler.py` — Bedrock RCA + SES HTML email
- `lambda/parse_insight/handler.py` — DevOps Guru insight parsing helper
- `monitoring/grafana/` — provisioned datasource + the 6-panel Golden Signals dashboard
- `chaos/chaos.py` — three chaos scenarios (`http_500`, `cpu_spike`, `memory_leak`)
- `chaos/verify_healing.sh` — automated inject → heal verification driven over SSM
- `tests/` — pytest suite (`test_app.py`, `test_remediator.py`, `test_rca_summariser.py`)
- `requirements-dev.txt` — test dependencies (app deps + pytest)
- `.github/workflows/ci.yml` — pytest, `terraform fmt`/`validate`, and a tfsec scan
- `terraform/` — root module and child modules (`vpc`, `compute`, `asg`, `alarms`,
  `lambda`, `devops_guru`, `monitoring`)
- `docs/` — this README, the architecture overview, and the full lab walkthrough

## Getting started

Follow the full lab in [docs/WALKTHROUGH.md](WALKTHROUGH.md). The short version:

1. Verify an SES email identity and confirm Bedrock access (`anthropic.claude-sonnet-4-6`).
2. `cd terraform`, copy `terraform.tfvars.example` to `terraform.tfvars`, fill it in.
3. `terraform init && terraform apply` — provisions ~55–60 resources.
4. Open Grafana at the `grafana_url` output, then inject chaos and watch the system heal.

> `pip3` must work on your machine before `terraform apply`: a `null_resource` stages
> Python wheels (and the `node_exporter` binary) to a private S3 bucket, which the
> private app instances pull via the S3 gateway endpoint — they never touch the internet.

## Run the tests

```bash
pip install -r requirements-dev.txt
pytest
```

This runs the 16-test suite covering the Flask endpoints, the remediator decision logic,
and the RCA summariser (including the Bedrock-unavailable fallback). The same checks run
in CI on every push and pull request, alongside `terraform fmt -check`/`validate` and a
tfsec IaC security scan.

## Notes

- SES is in sandbox mode on new accounts — verify every sender/recipient address first.
- If Bedrock is blocked by an organizational SCP, the RCA email still arrives: the Lambda
  falls back to a raw-insight summary and flags it with a yellow banner.
