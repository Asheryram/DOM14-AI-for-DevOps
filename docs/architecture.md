# TechStream Self-Healing System — Architecture

> **Diagram**: open [techstream-architecture.drawio](techstream-architecture.drawio) in draw.io (desktop or diagrams.net).

## Overview

TechStream is a self-healing pipeline for a Flask-based data-ingestion service running on AWS.
When the service degrades, the system detects the anomaly, remediates automatically, and emails
an AI-generated root-cause analysis — with no human intervention.

Everything runs in **eu-west-1**. The app instances and the monitoring instance both run
**Amazon Linux 2023**. There is **no ALB, no NAT gateway, and no Docker** in the system — the
app fleet is fully private and reaches AWS only through VPC endpoints.

---

## Infrastructure (Terraform modules)

| Module | What it provisions |
|--------|-------------------|
| `modules/vpc` | VPC (10.0.0.0/16), 2 public + 2 private subnets across 2 AZs, IGW, public/private route tables, and **6 VPC endpoints** — S3 gateway (free) plus interface endpoints for `ssm`, `ssmmessages`, `ec2messages`, `monitoring` (CloudWatch metrics), and `logs` (CloudWatch Logs). **No NAT gateway.** |
| `modules/compute` | Private S3 bucket for pre-staged artifacts; a `null_resource` that stages Python wheels and the `node_exporter` binary to S3; app security group (port 8000); IAM instance profile (SSM + CloudWatch + S3 read); EC2 launch template with AL2023 user-data. |
| `modules/asg` | Auto Scaling Group (min 2 / max 10, desired 2) wired to the launch template and the **private** subnets, with an instance refresh on launch-template change. |
| `modules/alarms` | **Two** SNS topics (`-alerts` and `-insights`) and 3 CloudWatch alarms (Error Rate > 5 %, CPU > 85 %, Memory > 90 %), all dimensioned by `AutoScalingGroupName`. |
| `modules/lambda` | Remediator Lambda, RCA Summariser Lambda, EventBridge rule → Remediator, the RCA Lambda's subscription to the insights topic, and 4 CloudWatch log groups. |
| `modules/devops_guru` | Amazon DevOps Guru resource collection (CloudFormation stack) with the insights topic as its notification channel. |
| `modules/monitoring` | Public-subnet EC2 (t3.small) with an Elastic IP, security group, and an EC2-service-discovery IAM role; AL2023 user-data installs Prometheus (binary) and Grafana (RPM). |

> A `modules/amp` directory still exists in the tree but is **not wired into `main.tf`** —
> Amazon Managed Prometheus is not used. Metrics are scraped by the self-hosted Prometheus.

---

## Networking & access model

- **App ASG** — private subnets, **no public IP, no NAT, no inbound internet path**. Managed
  exclusively through **SSM Session Manager** (no SSH; port 22 is not open). All outbound AWS
  access goes through the VPC endpoints listed above; package downloads at boot come from the
  private S3 bucket over the S3 gateway endpoint.
- **Monitoring EC2** — public subnet with a public IP + Elastic IP (a stable URL). Grafana
  (3000) is open to `0.0.0.0/0`; Prometheus (9090) is reachable only within the VPC. SSH is
  not open here either — management is via SSM.

---

## Key data flows

### 1 — Metrics collection

```
App instance (Amazon Linux 2023)
  ├── Flask app (gunicorn, systemd unit `techstream`) on :8000
  │     ├── /metrics  ─────────────► Prometheus  (EC2 SD, job: techstream_app)
  │     └── PutMetricData ─────────► CloudWatch  (TechStream/GoldenSignals:
  │                                   5xx_error_rate + mem_used_percent)
  └── node_exporter on :9100  ─────► Prometheus  (EC2 SD, job: node)
```

The Flask app exposes Prometheus metrics (`techstream_request_total`,
`techstream_request_latency_seconds`, `techstream_error_total`) and a background thread that
publishes `5xx_error_rate` (only when there is traffic) and `mem_used_percent` (every cycle) to
the `TechStream/GoldenSignals` CloudWatch namespace, dimensioned by `AutoScalingGroupName`.

### 2 — Grafana dashboard

```
Browser ──► IGW ──► Monitoring EC2 (Elastic IP)
                      ├── Grafana :3000  ──► Prometheus datasource (http://localhost:9090)
                      └── Prometheus :9090 ──► EC2 SD over the ASG (jobs: techstream_app, node)
```

Prometheus runs as a binary under systemd with two EC2-service-discovery scrape jobs over the
same ASG: `techstream_app` (port 8000) and `node` (port 9100, node_exporter). Grafana is
installed from the official RPM; its single Prometheus datasource points at
`http://localhost:9090`, and the 6-panel Golden Signals dashboard is provisioned from a file:
Latency (p50/p95/p99), Traffic (req/s), Error Rate (5xx %), Saturation (CPU %),
Error Count by Status, and Memory Usage %.

### 3 — Self-healing remediation

```
CW Alarm (state → ALARM)
  ├── EventBridge Rule (filters state=ALARM) ──► Remediator Lambda
  │        if InService < desired  ──► ASG SetDesiredCapacity (+2)   [scale out]
  │        else                     ──► SSM SendCommand: restart `techstream`,
  │                                       poll the invocation for real success/failure
  └── SNS `-alerts` topic ──► on-call + incidents email (alarm AND OK notifications)
```

EventBridge is the **single** remediation trigger: its event pattern filters to `state=ALARM`
and the three alarm names, so the remediator fires exactly once per alarm and never on
OK/INSUFFICIENT_DATA. The remediator is **not** subscribed to SNS, which avoids double-firing
and avoids acting on recovery notifications. (The handler still defensively ignores any
non-ALARM event it receives.) Each run writes an audit entry to the
`/techstream/remediation-events` log group.

### 4 — AI root-cause analysis

```
Amazon DevOps Guru ──► SNS `-insights` topic ──► RCA Summariser Lambda (subscribed here only)
                                                    ├── Bedrock InvokeModel
                                                    │     (anthropic.claude-sonnet-4-6)
                                                    └── SES (raw HTML email ──► incidents + on-call)
```

The RCA Summariser subscribes **only** to the dedicated `-insights` topic (separate from
`-alerts`) so it is never invoked on routine alarm notifications, and it guards against
non-insight messages. If Bedrock is blocked (e.g. by an organizational SCP), it falls back to a
summary extracted directly from the raw DevOps Guru insight, flags the email with a yellow
banner, and always attaches `insight_export.json`. It publishes a `bedrock_available` metric to
the `TechStream/RCA` namespace so a permanently-broken AI path is visible.

### 5 — Chaos engineering

```
Operator laptop ──► SSM Run Command ──► App instance ──► chaos.py against localhost:8000
                                                            ├── http_500     →  5xx error rate spikes
                                                            ├── cpu_spike    →  CPU saturation
                                                            └── memory_leak  →  memory pressure
```

Because the app fleet is private (no ALB, no public ingress), `chaos/chaos.py` is designed to
run **on an app instance via SSM** and target the local Flask process at `localhost:8000`.
`chaos/verify_healing.sh` automates the whole cycle from the operator's laptop: it discovers an
InService instance from the ASG, ships `chaos.py` to it over SSM, runs the `http_500` scenario
against `localhost:8000`, then polls the CloudWatch alarm and the `5xx_error_rate` metric until
the system heals.

---

## Deployment sequence

```
1. cd terraform && terraform init && terraform apply
   # provisions VPC → compute → ASG → alarms → lambda → devops_guru → monitoring (~55–60 resources)
   # the compute module stages Python wheels + node_exporter to S3 via a local null_resource
2. Open the grafana_url output → log in (admin / grafana_admin_password)
3. Run chaos on an instance via SSM (or ./chaos/verify_healing.sh --region eu-west-1)
4. Watch the alarm fire → EventBridge invokes the Remediator → service restarts → alarm returns to OK
5. Check /techstream/remediation-events in CloudWatch Logs for the action record
6. Check the SES inbox for the DevOps Guru RCA email
```

---

## Component map

```
docs/
  techstream-architecture.drawio   ← full diagram
  WALKTHROUGH.md                   ← step-by-step lab guide
terraform/
  main.tf                          ← root module wiring all child modules
  modules/vpc/                     ← VPC, subnets, IGW, 6 VPC endpoints (no NAT)
  modules/compute/                 ← S3 artifact bucket + launch template + AL2023 user-data
  modules/asg/                     ← Auto Scaling Group
  modules/alarms/                  ← 3 CloudWatch alarms + 2 SNS topics
  modules/lambda/                  ← Remediator + RCA Summariser + EventBridge rule
  modules/devops_guru/             ← DevOps Guru resource collection
  modules/monitoring/              ← EC2 + Elastic IP running Prometheus + Grafana (AL2023, no Docker)
lambda/
  remediator/handler.py            ← scale-out or SSM restart of the `techstream` unit
  rca_summariser/handler.py        ← Bedrock RCA (with raw-insight fallback) + SES email
app/
  app.py                           ← Flask ingest API with Prometheus metrics
chaos/
  chaos.py                         ← fault-injection scenarios (run on an instance via SSM)
  verify_healing.sh                ← SSM-driven inject → heal verification
tests/
  test_app.py / test_remediator.py / test_rca_summariser.py  ← pytest suite (16 tests)
.github/workflows/ci.yml           ← pytest + terraform fmt/validate + tfsec
```
