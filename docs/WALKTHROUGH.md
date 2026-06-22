# TechStream Self-Healing System — Full Walkthrough

> Follow this document top-to-bottom on a clean AWS account to go from zero to a
> running, self-healing system. Every command is copy-pasteable.

---

## Table of Contents

1. [What You Are Building](#1-what-you-are-building)
2. [Prerequisites](#2-prerequisites)
3. [AWS One-Time Setup](#3-aws-one-time-setup)
4. [Configure Terraform](#4-configure-terraform)
5. [Deploy Infrastructure](#5-deploy-infrastructure)
6. [Build and Push the Grafana Image](#6-build-and-push-the-grafana-image)
7. [Verify Every Component](#7-verify-every-component)
8. [Explore the Grafana Dashboard](#8-explore-the-grafana-dashboard)
9. [Run a Chaos Scenario](#9-run-a-chaos-scenario)
10. [Watch Self-Healing in Real Time](#10-watch-self-healing-in-real-time)
11. [Read the AI Root-Cause Analysis Email](#11-read-the-ai-root-cause-analysis-email)
12. [Automated Healing Verification](#12-automated-healing-verification)
13. [Tear Down](#13-tear-down)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. What You Are Building

```
Browser ──► ALB ──► Grafana (ECS Fargate)
                         └──► AMP (PromQL)

chaos.py ──► Flask app (EC2 ASG, private subnet)
                  ├──► Prometheus ──► AMP (remote_write)
                  └──► CloudWatch (5xx_error_rate)
                              └──► CW Alarm
                                       ├──► EventBridge ──► Remediator Lambda
                                       │                         ├──► SSM (restart)
                                       │                         └──► ASG (scale-out)
                                       └──► SNS
                                                └──► RCA Lambda ──► Bedrock ──► SES ──► email
```

**Self-healing loop:**
`Fault injected → Error rate spikes → CW Alarm fires → EventBridge triggers Lambda
→ Lambda restarts Flask or scales ASG → Error rate recovers → Bedrock emails RCA`

The entire loop runs without any human action.

---

## 2. Prerequisites

### Local tools

| Tool | Minimum version | Install |
|------|----------------|---------|
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | 1.5 | https://developer.hashicorp.com/terraform/install |
| Docker Desktop | 24 | https://www.docker.com/products/docker-desktop/ |
| Python | 3.11 | https://www.python.org/downloads/ |
| Git | any | pre-installed on most systems |

Confirm each is available:

```bash
aws --version
terraform --version
docker --version
python3 --version
```

### Python dependencies for chaos scripts

```bash
pip3 install requests psutil boto3
```

### AWS credentials

Configure a profile with sufficient permissions (EC2, ECS, ECR, Lambda, CloudWatch,
AMP, SSM, SES, Bedrock, DevOps Guru, IAM, VPC):

```bash
aws configure
# AWS Access Key ID: <your key>
# AWS Secret Access Key: <your secret>
# Default region name: us-east-1
# Default output format: json
```

Verify access:

```bash
aws sts get-caller-identity
```

---

## 3. AWS One-Time Setup

These are manual steps in the AWS console that must be done before Terraform runs.

### 3.1 Verify email addresses in SES

The system sends email from three addresses. All three must be verified in SES.

```
devops-guru@yourdomain.com   ← the FROM address (ses_from_email)
oncall@yourdomain.com        ← on-call alerts (oncall_email)
incidents@yourdomain.com     ← RCA reports (incidents_email)
```

You can use the same real email address for all three during a demo.

```bash
# Verify each address (replace with your real email)
aws ses verify-email-identity --email-address devops-guru@yourdomain.com --region us-east-1
aws ses verify-email-identity --email-address oncall@yourdomain.com     --region us-east-1
aws ses verify-email-identity --email-address incidents@yourdomain.com  --region us-east-1
```

Check your inbox for three verification emails from AWS and click each link.

> **SES sandbox**: New AWS accounts are in the SES sandbox, which means you can only
> send to verified addresses. The demo works fine as long as all three addresses above
> are verified. To remove the sandbox restriction, submit a production access request
> in the SES console — but this is not required for the walkthrough.

### 3.2 Enable Bedrock model access

1. Open the [Amazon Bedrock console](https://console.aws.amazon.com/bedrock)
2. Navigate to **Model access** (left sidebar)
3. Click **Manage model access**
4. Tick **Claude Sonnet** (Anthropic)
5. Click **Request model access** → wait for status to show **Access granted**

### 3.3 Confirm your region supports all services

This walkthrough uses `us-east-1`. All required services (AMP, DevOps Guru, Bedrock
with Claude, ECS Fargate, ECR) are available there. If you use a different region,
verify AMP and DevOps Guru availability first.

---

## 4. Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in the values below. Every other field has a
working default you can leave unchanged.

```hcl
# ── Required: your region ─────────────────────────────────────────────────────
aws_region  = "us-east-1"
environment = "prod"

# ── Required: email addresses (must be SES-verified, see step 3.1) ───────────
oncall_email    = "you@yourdomain.com"
incidents_email = "you@yourdomain.com"
ses_from_email  = "you@yourdomain.com"

# ── Required: Grafana login password ─────────────────────────────────────────
grafana_admin_password = "MySecure#Password1"

# ── Optional: keep defaults unless you have a reason to change ───────────────
vpc_cidr              = "10.0.0.0/16"
instance_type         = "t3.medium"
key_name              = ""                # leave empty — SSH not needed
asg_min_size          = 2
asg_max_size          = 10
asg_desired_capacity  = 2
bedrock_model_id      = "us.anthropic.claude-sonnet-4-6-20251001-v1:0"
cloudformation_stack_name = "TechStream-Prod"
```

> `terraform.tfvars` is gitignored. Never commit it — it contains your Grafana password.

---

## 5. Deploy Infrastructure

```bash
# Still inside terraform/
terraform init
```

Expected output:
```
Terraform has been successfully initialized!
```

```bash
terraform plan -out=tfplan
```

Review the plan. You should see resources being created across all 8 modules.
No resources should be destroyed on a fresh account.

```bash
terraform apply tfplan
```

This takes approximately **4–6 minutes**. Terraform creates resources in this order:

| Step | Module | What happens |
|------|--------|-------------|
| 1 | `vpc` | VPC, 2 public subnets, 2 private subnets, IGW, NAT GW, route tables |
| 2 | `amp` | AMP workspace created; remote_write URL stored in SSM Parameter Store |
| 3 | `compute` | AL2023 AMI looked up; security group, IAM role, launch template created |
| 4 | `asg` | ASG created; EC2 instances launch in private subnets and bootstrap via user-data |
| 5 | `alarms` | SNS topic created; 3 CloudWatch alarms defined; email subscriptions sent |
| 6 | `lambda` | Lambda functions zipped and deployed; EventBridge rule created |
| 7 | `devops_guru` | DevOps Guru starts monitoring the CloudFormation stack |
| 8 | `monitoring` | ECR repo created; ECS cluster + ALB + task definition created (service stays PENDING until image is pushed) |

When apply completes, copy the outputs to a notepad:

```
Outputs:

grafana_url             = "http://techstream-prod-grafana-XXXXXXXXX.us-east-1.elb.amazonaws.com"
ecr_repository_url      = "ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/techstream-prod-grafana"
asg_name                = "TechStream-prod-ASG"
sns_topic_arn           = "arn:aws:sns:us-east-1:ACCOUNT:TechStream-prod-Alerts"
amp_remote_write_url    = "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-XXXX/api/v1/remote_write"
amp_ssm_parameter       = "/TechStream-prod/amp/remote-write-url"
remediator_function_arn = "arn:aws:lambda:us-east-1:ACCOUNT:function:TechStream-prod-Remediator"
vpc_id                  = "vpc-XXXXXXXXX"
```

**Accept the SNS subscription emails** — check your inbox for two emails titled
"AWS Notification - Subscription Confirmation" and click the confirmation link in each.
If you skip this, email alerts will not be delivered.

---

## 6. Build and Push the Grafana Image

The ECS service is waiting for a Docker image in ECR. Once pushed, the service
starts within about 60 seconds.

```bash
# From the repo root (one level above terraform/)
cd ..

# Authenticate Docker to ECR
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
```

Expected: `Login Succeeded`

```bash
# Build the custom Grafana image
# (bakes datasource + dashboard provisioning YAML into the image)
docker build \
  -f monitoring/Dockerfile.grafana \
  -t techstream-grafana \
  .
```

```bash
# Tag and push to ECR
docker tag techstream-grafana \
  ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/techstream-prod-grafana:latest

docker push \
  ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/techstream-prod-grafana:latest
```

After the push completes the ECS service detects the new image and starts.
Wait about 90 seconds, then verify:

```bash
aws ecs describe-services \
  --cluster TechStream-prod-grafana \
  --services TechStream-prod-grafana \
  --region us-east-1 \
  --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}'
```

Expected:
```json
{
    "Status": "ACTIVE",
    "Running": 1,
    "Desired": 1
}
```

---

## 7. Verify Every Component

Run these checks before proceeding to chaos. Each should return the expected value.

### 7.1 EC2 instances are healthy

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names TechStream-prod-ASG \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}'
```

Expected: two instances, both `InService` / `Healthy`.

### 7.2 Flask app is running on EC2

The EC2 instances are in private subnets (no direct internet access). Check via SSM:

```bash
# Get one instance ID from the ASG output above, then:
aws ssm send-command \
  --instance-ids i-XXXXXXXXXXXXXXXXX \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl is-active flask-app && curl -s localhost:8000/api/v1/health"]}' \
  --region us-east-1 \
  --query 'Command.CommandId' \
  --output text
```

```bash
# Wait 10 seconds, then retrieve output:
aws ssm get-command-invocation \
  --command-id COMMAND_ID \
  --instance-id i-XXXXXXXXXXXXXXXXX \
  --region us-east-1 \
  --query 'StandardOutputContent'
```

Expected output includes `active` and `{"status": "healthy"}`.

### 7.3 Prometheus is shipping to AMP

```bash
aws ssm send-command \
  --instance-ids i-XXXXXXXXXXXXXXXXX \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl is-active prometheus && curl -s localhost:9090/api/v1/query?query=up"]}' \
  --region us-east-1 \
  --query 'Command.CommandId' --output text
```

Expected: `active` and a JSON response with `"status":"success"`.

### 7.4 CloudWatch alarms are in OK state

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix TechStream-prod \
  --region us-east-1 \
  --query 'MetricAlarms[*].{Alarm:AlarmName,State:StateValue}'
```

Expected:
```json
[
  {"Alarm": "TechStream-prod-ErrorRate-High", "State": "OK"},
  {"Alarm": "TechStream-prod-CPU-High",       "State": "OK"},
  {"Alarm": "TechStream-prod-Memory-High",    "State": "OK"}
]
```

> Alarms may show `INSUFFICIENT_DATA` for the first 5 minutes while CloudWatch
> collects the first data points. Wait and re-run.

### 7.5 EventBridge rule is enabled

```bash
aws events describe-rule \
  --name TechStream-prod-AlarmToRemediation \
  --region us-east-1 \
  --query '{State:State,EventPattern:EventPattern}'
```

Expected: `"State": "ENABLED"`.

### 7.6 Lambda functions exist and are active

```bash
aws lambda list-functions \
  --region us-east-1 \
  --query 'Functions[?starts_with(FunctionName,`TechStream`)].{Name:FunctionName,State:State}'
```

Expected:
```json
[
  {"Name": "TechStream-prod-Remediator",   "State": "Active"},
  {"Name": "TechStream-prod-RCASummariser","State": "Active"}
]
```

### 7.7 Grafana is reachable

```bash
curl -s -o /dev/null -w "%{http_code}" \
  http://techstream-prod-grafana-XXXXXXXXX.us-east-1.elb.amazonaws.com/api/health
```

Expected: `200`

---

## 8. Explore the Grafana Dashboard

1. Open the `grafana_url` in your browser
2. Login: username `admin`, password = the value of `grafana_admin_password` in your tfvars
3. Navigate to **Dashboards → TechStream Golden Signals**

You will see 6 panels updating every 15 seconds:

| Panel | What it shows | Normal baseline |
|-------|--------------|----------------|
| Latency p50/p95/p99 | Request latency percentiles from AMP | p50 < 100 ms |
| Traffic req/s | Requests per second by endpoint | Depends on load |
| Error Rate % | 5xx percentage (stat, color-coded) | < 1 % (green) |
| CPU Saturation | CPU % per instance (gauge) | < 30 % (green) |
| Error Count by Status | Error breakdown by HTTP status | Near zero |
| Memory % | Memory utilisation per instance | < 60 % (green) |

Confirm the AMP datasource is connected: **Configuration → Data Sources → AMP → Save & Test** should return `Data source connected and labels found`.

---

## 9. Run a Chaos Scenario

> Run this from your laptop. The chaos script talks to the Flask app through the
> internet (via ALB) or you can run it from a bastion host inside the VPC.

You need the DNS name of the **application** ALB — not the Grafana ALB.
The app ALB is created by the `asg` module and forwards traffic on port 8000
to the EC2 instances. Get it:

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName,`TechStream`)].DNSName' \
  --output text
```

Run the HTTP 500 scenario for 3 minutes:

```bash
python3 chaos/chaos.py \
  --scenario http_500 \
  --alb-dns techstream-prod-app-XXXXXXXXX.us-east-1.elb.amazonaws.com \
  --duration 180 \
  --region us-east-1
```

You will see live output:

```
[http_500] elapsed=177s remaining  errors=412   total=415
[http_500] elapsed=147s remaining  errors=1247  total=1252
[http_500] elapsed=117s remaining  errors=2083  total=2090
...
```

**While the scenario runs**, watch the Grafana dashboard:
- Error Rate % climbs from < 1 % → 40–50 % (panel turns red)
- Traffic req/s spikes sharply
- Latency may increase as Flask handles malformed payloads

### Other scenarios

```bash
# CPU saturation — fires the CPU alarm instead of ErrorRate
python3 chaos/chaos.py --scenario cpu_spike --alb-dns <ALB_DNS> --duration 180

# Memory pressure — fires the Memory alarm
python3 chaos/chaos.py --scenario memory_leak --alb-dns <ALB_DNS> --duration 180

# Network latency — visible on the Latency panel
python3 chaos/chaos.py --scenario network_stress --alb-dns <ALB_DNS> --duration 180
```

---

## 10. Watch Self-Healing in Real Time

Open two terminal windows.

**Terminal A — stream the remediation log:**

```bash
aws logs tail /techstream/remediation-events \
  --follow \
  --region us-east-1
```

**Terminal B — watch the alarm state:**

```bash
watch -n 10 "aws cloudwatch describe-alarms \
  --alarm-name-prefix TechStream-prod \
  --region us-east-1 \
  --query 'MetricAlarms[*].{Alarm:AlarmName,State:StateValue}'"
```

### Timeline of what you will observe

**~T+2 min after chaos starts**
The error rate alarm changes state. Terminal B shows:
```
TechStream-prod-ErrorRate-High  →  ALARM
```

**~T+2 min (within seconds of ALARM)**
EventBridge delivers the alarm event to the Remediator Lambda. Terminal A shows:

```json
{
  "timestamp": "2026-06-22T10:15:32Z",
  "alarm_name": "TechStream-prod-ErrorRate-High",
  "action_taken": "service_restart",
  "result": "success",
  "duration_ms": 3241
}
```

**~T+2.5 min**
SSM `send-command` executes on all InService EC2 instances:
```
sudo systemctl restart flask-app && sleep 5 && systemctl is-active flask-app
```
Flask restarts in ~5 seconds per instance.

**~T+3 min**
The error rate drops back below 1 %. The CloudWatch alarm transitions:
```
TechStream-prod-ErrorRate-High  →  OK
```
The Grafana Error Rate panel turns green.

**Check Lambda execution metrics:**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=TechStream-prod-Remediator \
  --start-time $(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 900 --statistics Sum \
  --region us-east-1 \
  --query 'Datapoints[0].Sum'
```

Expected: `1.0` (one invocation for this chaos run).

**Check ASG scaling activity** (if scale-out was triggered instead of restart):

```bash
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name TechStream-prod-ASG \
  --region us-east-1 \
  --max-items 5 \
  --query 'Activities[*].{Time:StartTime,Description:Description,Status:StatusCode}'
```

---

## 11. Read the AI Root-Cause Analysis Email

Amazon DevOps Guru analyses the anomaly pattern and publishes an insight to the SNS
topic. The RCA Summariser Lambda is subscribed and fires within ~60 seconds of the
insight arriving.

Check your `incidents_email` inbox for a message with subject:
```
[TechStream RCA] Anomaly detected — <timestamp>
```

The HTML email body contains:

```
Executive Summary
─────────────────
The TechStream Flask ingestion service experienced a 5xx error rate spike of 47%
beginning at 10:13 UTC on 2026-06-22, lasting approximately 3 minutes before
automated remediation restored normal operation.

Root Cause
──────────
A flood of malformed POST requests to /api/v1/ingest caused the Flask application
to return HTTP 500 responses for every malformed payload. The application does not
implement request-rate throttling, allowing the error rate to exceed the 5% alarm
threshold within 2 minutes.

Impact
──────
• Affected endpoints: POST /api/v1/ingest
• Duration: ~3 minutes (10:13 – 10:16 UTC)
• Error rate peak: 47.3%
• Healthy instances: 2 (not reduced — ASG capacity was maintained)

Remediation
───────────
Automated: TechStream-prod-Remediator Lambda restarted the flask-app systemd
service on 2 EC2 instances via SSM Run Command at 10:15:32 UTC.
Recovery time from alarm to green: 4 minutes 18 seconds.

Prevention Recommendations
──────────────────────────
1. Add request-rate limiting (e.g., Flask-Limiter) to cap malformed-payload volume.
2. Implement input validation middleware that returns 400 (not 500) for malformed payloads.
3. Enable WAF on the ALB to block automated flood patterns before they reach Flask.
```

> The content above is illustrative — the actual text is generated by Bedrock from
> the real DevOps Guru insight payload and will vary.

If the email did not arrive, check:

```bash
# RCA Lambda invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=TechStream-prod-RCASummariser \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 1800 --statistics Sum \
  --region us-east-1

# RCA Lambda logs
aws logs tail /aws/lambda/TechStream-prod-RCASummariser \
  --since 30m --region us-east-1
```

---

## 12. Automated Healing Verification

`verify_healing.sh` captures a before/after snapshot and asserts the system healed.

```bash
chmod +x chaos/verify_healing.sh

./chaos/verify_healing.sh \
  --alb-dns techstream-prod-app-XXXXXXXXX.us-east-1.elb.amazonaws.com \
  --region us-east-1
```

The script runs through four stages:

```
=== TechStream Self-Healing Verification ===
Target  : http://techstream-prod-app-XXXXXXXXX.us-east-1.elb.amazonaws.com
Region  : us-east-1
Alarm   : TechStream-prod-ErrorRate-High

[1/4] Recording baseline 5xx error rate...
      Baseline: 0.12%

[2/4] Injecting http_500 chaos (180s)...
      [chaos running — watch Grafana and Terminal B for alarm state]

[3/4] Waiting for alarm to fire (polling every 30s, timeout 600s)...
      T+120s → Alarm state: ALARM  ✓

[4/4] Waiting for recovery (polling every 30s, timeout 600s)...
      T+150s → Alarm state: ALARM
      T+180s → Alarm state: ALARM
      T+210s → Alarm state: OK    ✓
      Recovery error rate: 0.09%

=== Result ===
Baseline error rate : 0.12%
Peak alarm state    : ALARM (confirmed)
Recovery error rate : 0.09%
Healing time        : 4m 32s
PASS — system healed within tolerance (≤ baseline + 1.0%)
```

A non-zero exit code means the alarm never fired or the system did not recover
within 10 minutes.

---

## 13. Tear Down

When you are done, destroy all resources to avoid ongoing costs.

```bash
cd terraform

terraform destroy
```

Type `yes` when prompted. This destroys every resource Terraform manages in reverse
dependency order.

**Estimated monthly cost if left running:**
- ECS Fargate (0.5 vCPU, 1 GB): ~$15
- 2× EC2 t3.medium: ~$60
- NAT Gateway: ~$32 (+ data transfer)
- AMP: ~$0 (free tier covers low ingestion volumes)
- ALBs: ~$16
- Lambda: < $1

Total: ~$120/month. Destroy after the demo.

---

## 14. Troubleshooting

### ECS task stays in PENDING / STOPPED

```bash
# Check stopped task failure reason
aws ecs describe-tasks \
  --cluster TechStream-prod-grafana \
  --tasks $(aws ecs list-tasks --cluster TechStream-prod-grafana --query 'taskArns[0]' --output text) \
  --region us-east-1 \
  --query 'tasks[0].{Status:lastStatus,Reason:stoppedReason}'
```

Most common causes:
- **Image not found in ECR** — run Step 6 (build + push) and wait 90 seconds
- **Task role lacks `aps:QueryMetrics`** — check the monitoring module IAM policy
- **Health check failing** — Grafana starts slowly; ALB health check grace period is 120 s

### CloudWatch alarms stuck in INSUFFICIENT_DATA

This is normal for the first 5–10 minutes. Alarms need at least 2 data points before
evaluating. Wait and re-run the check in step 7.4.

If they stay in `INSUFFICIENT_DATA` after 15 minutes:

```bash
# Check that EC2 instances are publishing metrics
aws cloudwatch list-metrics \
  --namespace TechStream/GoldenSignals \
  --region us-east-1
```

If no metrics appear, SSH into an instance (set `key_name` in tfvars and re-apply)
and check `systemctl status flask-app` and `systemctl status prometheus`.

### Lambda shows errors in CloudWatch Logs

```bash
aws logs tail /aws/lambda/TechStream-prod-Remediator \
  --since 1h --region us-east-1
```

Common errors and fixes:

| Error message | Fix |
|--------------|-----|
| `AccessDeniedException: ses:SendEmail` | Verify the SES from-address and confirm sandbox restrictions (step 3.1) |
| `AccessDeniedException: bedrock:InvokeModel` | Enable Claude Sonnet in Bedrock console (step 3.2) |
| `ResourceNotFoundException: ASG not found` | The `ASG_NAME` env var on the Lambda must match the ASG name — check `module.asg.name` output |
| `SSM: InvalidInstanceId` | Instances may not have the SSM agent running — AL2023 includes it by default; check IAM instance profile includes `AmazonSSMManagedInstanceCore` |

### Grafana shows "no data" on panels

1. **Check the datasource**: Configuration → Data Sources → AMP → Save & Test
2. **Check AMP is receiving data**: 
   ```bash
   aws amp query-metrics \
     --workspace-id $(aws amp list-workspaces --query 'workspaces[0].workspaceId' --output text) \
     --query 'up' \
     --region us-east-1
   ```
3. **Check Prometheus on EC2** is running and can reach AMP:
   ```bash
   aws ssm send-command --instance-ids i-XXX \
     --document-name AWS-RunShellScript \
     --parameters '{"commands":["journalctl -u prometheus --since \"5 minutes ago\" | tail -20"]}' \
     --region us-east-1 --query 'Command.CommandId' --output text
   ```

### SES emails not arriving

1. Confirm subscription confirmation emails were clicked (step 5)
2. Check SES verified identities:
   ```bash
   aws ses list-verified-email-addresses --region us-east-1
   ```
3. Check SES sending statistics for bounces or blocks:
   ```bash
   aws ses get-send-statistics --region us-east-1
   ```

### chaos.py fails with connection error

The Flask app ALB is separate from the Grafana ALB. Make sure you are using the
correct ALB DNS name (step 9). If the app ALB does not exist, check that the ASG
module created a target group and the instances registered successfully.

---

## Summary Checklist

```
[ ] SES: three email addresses verified
[ ] Bedrock: Claude Sonnet model access granted
[ ] terraform.tfvars filled in
[ ] terraform apply completed — all 8 modules green
[ ] SNS subscription confirmation emails clicked
[ ] Docker image built and pushed to ECR
[ ] ECS service: Running=1, Desired=1
[ ] 2 EC2 instances InService in ASG
[ ] All 3 CloudWatch alarms in OK state
[ ] Grafana reachable and Golden Signals dashboard showing data
[ ] chaos.py run — error rate spiked on dashboard
[ ] Remediator Lambda invoked — audit log entry in /techstream/remediation-events
[ ] Alarm returned to OK — Grafana panel green
[ ] RCA email received in incidents inbox
[ ] verify_healing.sh returned PASS
[ ] terraform destroy completed
```
