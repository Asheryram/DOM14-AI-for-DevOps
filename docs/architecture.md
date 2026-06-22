# TechStream Self-Healing System — Architecture

> **Diagram**: open [techstream-architecture.drawio](techstream-architecture.drawio) in draw.io (desktop or diagrams.net).

## Overview

TechStream is a self-healing pipeline for a Flask-based data-ingestion service running on AWS.  
When the service degrades, the system detects the anomaly, remediates automatically, and emails an AI-generated root-cause analysis — with no human intervention.

---

## Infrastructure (Terraform modules)

| Module | What it provisions |
|--------|-------------------|
| `modules/vpc` | VPC (10.0.0.0/16), 2 public + 2 private subnets across 2 AZs, IGW, NAT GW, route tables |
| `modules/amp` | Amazon Managed Service for Prometheus workspace, SSM parameter for remote_write URL, EC2 IAM policy |
| `modules/compute` | AL2023 AMI lookup, EC2 security group, IAM instance profile (SSM + CW Agent + AMP write), launch template, user-data bootstrap |
| `modules/asg` | Auto Scaling Group (min 2 / max 10) wired to the launch template and private subnets |
| `modules/alarms` | SNS alerts topic, 3 CloudWatch alarms (Error Rate > 5 %, CPU > 85 %, Memory > 90 %) |
| `modules/lambda` | Remediator Lambda, RCA Summariser Lambda, EventBridge rule → Remediator, SNS subscriptions, CloudWatch log groups |
| `modules/devops_guru` | Amazon DevOps Guru resource collection (CloudFormation stack), SNS notification channel |
| `modules/monitoring` | ECR repo (Grafana image), ECS Fargate cluster + task + service, ALB, IAM task role (AMP query + CloudWatch read) |

---

## Key data flows

### 1 — Metrics collection

```
Flask app (:8000)
  ├── /metrics  ──►  Prometheus (on same EC2)  ──►  AMP  (remote_write, SigV4)
  └── PutMetricData  ──►  CloudWatch  (5xx_error_rate namespace)
```

The AMP remote_write URL is stored in SSM Parameter Store at boot and read by the
Prometheus user-data template so instances self-configure without baking in endpoints.

### 2 — Grafana dashboard

```
Browser  ──►  IGW  ──►  ALB (:80)  ──►  ECS Fargate (Grafana :3000)
                                              └──► AMP (PromQL, SigV4 via task role)
                                              └──► CloudWatch (native datasource)
```

Grafana runs as a custom Docker image in ECR; provisioning YAML is baked in and uses
`${AMP_ENDPOINT}` / `${AWS_REGION}` env-var substitution (Grafana 9.1+).  
Four Golden Signal panels: Latency (p50/p95/p99), Traffic (req/s), Error Rate (5xx %), Saturation (CPU + Memory).

### 3 — Self-healing remediation

```
CW Alarm (ALARM state)
  ├── EventBridge Rule  ──►  Remediator Lambda  ──►  SSM SendCommand (restart flask-app)
  │                                              └──►  ASG SetDesiredCapacity (scale-out)
  └── SNS Topic  ──►  email (on-call team, fallback)
```

The EventBridge path is the primary trigger (direct, sub-second). SNS subscription is kept
as a fallback notification. The Lambda parses both event formats (`event.detail.alarmName`
for EventBridge; `event.Records[0].Sns.Message.AlarmName` for SNS).

### 4 — AI root-cause analysis

```
Amazon DevOps Guru  ──►  SNS Topic  ──►  RCA Summariser Lambda
                                              ├──►  Bedrock (Claude Sonnet — InvokeModel)
                                              └──►  SES (HTML RCA email  ──►  incidents team)
```

DevOps Guru monitors the CloudFormation stack and publishes anomaly insights to SNS.
The Lambda builds a structured prompt, calls Bedrock, and emails an HTML report via SES.

### 5 — Chaos engineering

```
Developer  ──►  chaos/chaos.py  ──►  Flask app endpoints
                                        ├── http_500 flood   →  5xx error rate spikes
                                        ├── cpu_spike        →  CPU saturation
                                        ├── memory_leak      →  memory pressure
                                        └── network_stress   →  latency increase
```

`chaos/verify_healing.sh` captures baseline metrics, triggers a scenario, waits, then
compares recovery metrics to confirm self-healing worked.

---

## Deployment sequence

```
1. terraform init && terraform apply          # provisions VPC → AMP → compute → ASG → alarms → lambda → monitoring
2. docker build -f monitoring/Dockerfile.grafana -t grafana-techstream .
   docker tag grafana-techstream <ECR_URL>:latest
   docker push <ECR_URL>:latest              # Grafana image → ECR
3. terraform apply                           # ECS service pulls image and starts
4. python chaos/chaos.py --scenario http_500 --duration 120
5. Watch Grafana dashboards → CloudWatch Alarm fires → Lambda remediates
6. Check /techstream/remediation-events CloudWatch Logs for action record
7. Check SES inbox for RCA email from Bedrock
```

---

## Component map

```
docs/
  techstream-architecture.drawio   ← full diagram
terraform/
  main.tf                          ← root module wiring all child modules
  modules/vpc/                     ← networking (VPC, subnets, NAT)
  modules/amp/                     ← Amazon Managed Prometheus
  modules/compute/                 ← EC2 launch template + user-data
  modules/asg/                     ← Auto Scaling Group
  modules/alarms/                  ← CloudWatch alarms + SNS
  modules/lambda/                  ← Remediator + RCA Summariser + EventBridge
  modules/devops_guru/             ← DevOps Guru resource collection
  modules/monitoring/              ← ECR + ECS Fargate + ALB (Grafana)
lambda/
  remediator/handler.py            ← scale-out or SSM restart logic
  rca_summariser/handler.py        ← Bedrock RCA + SES email
monitoring/
  Dockerfile.grafana               ← custom Grafana image with provisioning baked in
  grafana/provisioning/            ← datasources (AMP + CloudWatch) + dashboard provider
  grafana/dashboards/              ← Golden Signals JSON dashboard
chaos/
  chaos.py                         ← fault injection scenarios
  verify_healing.sh                ← baseline/recovery comparison script
```
