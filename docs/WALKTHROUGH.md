# TechStream Self-Healing System — Lab Guide

**Duration:** 90–120 minutes  
**Level:** Intermediate AWS / DevOps

---

## Lab Objectives

By the end of this lab you will have:

- Deployed a fully automated self-healing pipeline on AWS using Terraform (no ALB, no NAT — a fully private app fleet)
- Visualised the Golden Signals in a self-hosted Grafana instance backed by Prometheus
- Observed Prometheus discovering app instances automatically via EC2 service discovery (both the app on :8000 and node_exporter on :9100)
- Injected real faults by running a chaos script on an app instance via SSM, and watched the alarms fire
- Observed an EventBridge rule trigger a Lambda that restarts the service automatically
- Received an AI-generated root-cause analysis email produced by Amazon Bedrock
- Confirmed system recovery using an automated verification script driven over SSM
- Run the local pytest suite and seen the CI pipeline that backs it

---

## Architecture at a Glance

```
[Browser]                                  [Operator laptop]
    │                                              │
    ▼                                              │ aws ssm send-command
[Monitoring EC2 — Elastic IP]                      ▼
  ├─ Grafana :3000                       [EC2 ASG — private subnets]
  └─ Prometheus :9090                      each instance (Amazon Linux 2023):
       └── EC2 SD ───────────────────────►   ├─ Flask app :8000  (systemd: techstream)
            (jobs: techstream_app :8000,      └─ node_exporter :9100
                   node :9100)                       │ chaos.py runs HERE via SSM,
                                                      │ hitting localhost:8000
                                        PutMetricData │
                                                      ▼
                                              [CloudWatch Alarms ×3]
                                               /                  \
                            EventBridge Rule (state=ALARM)     SNS: -alerts topic
                                    │                              │
                                    ▼                              └──► on-call + incidents email
                             [Remediator λ]                            (alarm AND OK)
                               ├─► SSM restart `techstream`
                               └─► ASG scale-out (+2)

[Amazon DevOps Guru] ──► SNS: -insights topic ──► [RCA Summariser λ]
                                                     ├─► Bedrock (Claude Sonnet 4.6)
                                                     └─► SES email ──► incidents + on-call
```

> There is **no ALB and no NAT gateway**. The app fleet is fully private; chaos and
> remediation both reach the instances over SSM. The two SNS topics are kept separate so
> the RCA Lambda fires only on DevOps Guru insights, never on routine alarm notifications.

---

## Prerequisites

### Tools — install before the lab

| Tool | Min version | Check |
|------|-------------|-------|
| AWS CLI v2 | 2.x | `aws --version` |
| Terraform | 1.9 | `terraform --version` |
| Python 3 | 3.11 | `python3 --version` |
| Git | any | `git --version` |

Install Python dependencies for the chaos scripts:

```bash
pip3 install requests psutil boto3
```

> **`pip3` is also required during `terraform apply`.** A `null_resource` provisioner runs `pip3 download` on your local machine to fetch pre-built Linux wheels (and stages the `node_exporter` binary), then uploads both to a private S3 bucket. The app EC2 instances pull those artifacts from S3 via the free VPC gateway endpoint — they never touch the internet. Confirm `pip3 --version` works in your shell before applying.
>
> On Windows: if `python3` triggers the Microsoft Store prompt, `pip3` is unaffected — the two aliases are separate. The `pip3 --version` check confirms it is working.

### AWS account requirements

- IAM user or role with broad permissions (EC2, Lambda, CloudWatch, SSM, SES, Bedrock, DevOps Guru, IAM, VPC)
- Default region: **eu-west-1** (all services used are available here)
- SES is in sandbox mode on new accounts — this is fine; you just need to verify the email addresses you will use

> **About the instances:** both the app ASG instances and the monitoring instance run **Amazon Linux 2023**. The app fleet is fully private (no public IP, no NAT, no SSH) and is managed only through **SSM Session Manager**. There is no Docker, no ECS, and no ALB anywhere in this lab.

---

## Task 0 — Configure AWS Credentials

Configure the AWS CLI to point at your account:

```bash
aws configure
```

Enter your Access Key ID, Secret Access Key, region (`eu-west-1`), and output format (`json`).

Verify it works:

```bash
aws sts get-caller-identity
```

**Expected output:**
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-user"
}
```

> If this command fails, stop here and fix your credentials before continuing.

---

## Task 1 — One-Time AWS Console Setup

These two steps must be done in the AWS Console before Terraform runs.
They cannot be automated because they require human verification.

### 1a — Verify email addresses in SES

The system sends three types of email:
- **From** address (SES requires this to be verified)
- **On-call alerts** (SNS alarm notifications)
- **Incidents inbox** (AI-generated RCA reports)

For this lab you can use the **same real email address** for all three.

Run these commands, replacing `you@example.com` with your actual email:

```bash
aws ses verify-email-identity \
  --email-address you@example.com \
  --region eu-west-1
```

Check your inbox. You will receive an email from AWS with the subject  
**"Amazon Web Services – Email Address Verification Request"**.  
Click the verification link inside it.

Confirm verification worked:

```bash
aws ses list-identities --identity-type EmailAddress --region eu-west-1
```

**Expected:** your email address appears in the `Identities` list.

### 1b — Confirm Bedrock access for Claude Sonnet

AWS no longer requires manual model activation — Bedrock foundation models are enabled automatically on first invocation. However, **Anthropic models require a one-time use-case submission** for first-time accounts before they will respond.

Verify access now by invoking the model directly from the CLI:

```bash
aws bedrock-runtime invoke-model \
  --region eu-west-1 \
  --model-id anthropic.claude-sonnet-4-6 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":10,"messages":[{"role":"user","content":"ping"}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/bedrock_test.json && echo "Access OK"
```

**Expected:** `Access OK` printed and `/tmp/bedrock_test.json` contains a short JSON response.

If you see `AccessDeniedException` referencing a **service control policy**, Bedrock has been blocked at the AWS Organizations level (common on DCE/sandbox accounts). You cannot override this from within the account.

**The lab still works.** The RCA Summariser Lambda catches the Bedrock failure and falls back to extracting data directly from the raw DevOps Guru insight — you will still receive the RCA email, just without the AI-generated narrative. The email includes a yellow banner indicating Bedrock was unavailable.

If you see `AccessDeniedException` without an SCP reference (first-time Anthropic account):

1. Open the [Bedrock Model Catalog](https://console.aws.amazon.com/bedrock/home?region=eu-west-1#/models) in the AWS Console
2. Search for **Claude Sonnet**, click on the model, then click **Open in playground**
3. Complete the one-time use-case form, then re-run the CLI command above

> If Bedrock is SCP-blocked, skip ahead to Task 2. Task 10 will note the difference in the email you receive.

---

## Task 2 — Explore the Repository

Before deploying anything, spend 5 minutes understanding what you are deploying.

```
terraform/
  main.tf                 ← wires all 7 child modules together
  variables.tf            ← every input the system accepts
  outputs.tf              ← URLs and ARNs printed after apply
  terraform.tfvars.example← template — you will copy and fill this in
  modules/
    vpc/           ← VPC, subnets, IGW, 6 VPC endpoints (S3 gateway + ssm/ssmmessages/ec2messages/monitoring/logs) — no NAT
    compute/       ← S3 artifact bucket + IAM role + AL2023 launch template (Flask app + node_exporter)
    asg/           ← Auto Scaling Group (min 2, max 10), private subnets, instance refresh
    alarms/        ← 2 SNS topics (-alerts, -insights) + 3 CloudWatch alarms
    lambda/        ← Remediator + RCA Summariser + EventBridge rule
    devops_guru/   ← registers the stack with Amazon DevOps Guru
    monitoring/    ← EC2 + Elastic IP running Prometheus + Grafana (AL2023, no Docker)

lambda/
  remediator/handler.py      ← decides: restart the `techstream` unit or scale out
  rca_summariser/handler.py  ← calls Bedrock (with raw-insight fallback), sends HTML email

app/
  app.py                     ← Flask ingestion API with Prometheus metrics
  requirements.txt           ← pip dependencies

monitoring/
  grafana/dashboards/
    techstream_golden_signals.json ← the 6-panel Golden Signals dashboard

chaos/
  chaos.py          ← 3 fault injection scenarios (run on an instance via SSM)
  verify_healing.sh ← automated inject → heal verification, driven over SSM

tests/
  test_app.py / test_remediator.py / test_rca_summariser.py ← pytest suite (16 tests)
.github/workflows/ci.yml ← pytest + terraform fmt/validate + tfsec
```

> Metrics are scraped by the self-hosted Prometheus on the monitoring EC2 — there is no Amazon Managed Prometheus, no ECS, and no ALB in this stack.

**Key files to skim before continuing:**

Open [lambda/remediator/handler.py](../lambda/remediator/handler.py) and note:
- `_parse_event(event)` — handles both EventBridge and (fallback) SNS event formats, and ignores any non-ALARM state
- The decision logic: if `in_service < desired` → scale out (+2); otherwise → restart the `techstream` systemd unit via SSM and poll the command result for real success/failure

Open [app/app.py](../app/app.py) and note:
- `techstream_request_latency_seconds` (Histogram), `techstream_request_total` and `techstream_error_total` (Counters) — Prometheus metrics exposed at `:8000/metrics`
- A background thread that publishes `5xx_error_rate` and `mem_used_percent` to the `TechStream/GoldenSignals` CloudWatch namespace every 60 seconds — this is what drives the CloudWatch alarms

Open [chaos/chaos.py](../chaos/chaos.py) and note:
- It is designed to run **on an app instance via SSM**, targeting the local Flask app at `localhost:8000` (the fleet is private — there is no public endpoint to hit from your laptop)
- `scenario_http_500` — floods `localhost:8000/api/v1/ingest` with 50 concurrent malformed POSTs/sec
- `scenario_cpu_spike` — pegs all CPUs (uses `stress-ng` if present, otherwise multiprocessing busy loops)
- `scenario_memory_leak` — allocates 10 MB chunks until the memory threshold is reached

---

## Task 3 — Configure Terraform

Copy the example variables file:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in your editor. Fill in **every field marked below**:

```hcl
# ── Region ────────────────────────────────────────────────────────────────────
aws_region  = "eu-west-1"      # ← keep this
environment = "prod"           # ← keep this

# ── Networking — Terraform creates the VPC, you don't touch these ─────────────
vpc_cidr = "10.0.0.0/16"

# ── Compute ───────────────────────────────────────────────────────────────────
instance_type = "t3.medium"
key_name      = ""             # leave empty — SSH not needed for this lab

# ── Auto Scaling ──────────────────────────────────────────────────────────────
asg_min_size         = 2
asg_max_size         = 10
asg_desired_capacity = 2

# ── Email addresses — REPLACE THESE WITH YOUR VERIFIED SES EMAIL ──────────────
oncall_email    = "you@example.com"    # ← CHANGE THIS
incidents_email = "you@example.com"    # ← CHANGE THIS (can be same address)
ses_from_email  = "you@example.com"    # ← CHANGE THIS (can be same address)

# ── Bedrock ───────────────────────────────────────────────────────────────────
bedrock_model_id = "anthropic.claude-sonnet-4-6"

# ── DevOps Guru ───────────────────────────────────────────────────────────────
cloudformation_stack_name = "TechStream-Prod"

# ── Grafana — CHANGE THE PASSWORD ─────────────────────────────────────────────
grafana_admin_password = "YourStrongPassword1!"   # ← CHANGE THIS
```

> `terraform.tfvars` is gitignored. Never commit it — it holds your Grafana password.

---

## Task 4 — Deploy Infrastructure with Terraform

### 4a — Initialise

```bash
terraform init
```

**Expected output (last line):**
```
Terraform has been successfully initialized!
```

### 4b — Review the plan

```bash
terraform plan -out=tfplan
```

Scroll through the plan. You should see **~55–60 resources** being created across 7 modules with no destroys. If you see any errors here, fix them before applying.

### 4c — Apply

```bash
terraform apply tfplan
```

This takes **6–9 minutes**. Watch what Terraform creates in order:

| Order | Module | What is created |
|-------|--------|----------------|
| 1st | `vpc` | VPC `10.0.0.0/16`, 2 public + 2 private subnets, Internet Gateway, public/private route tables — **no NAT Gateway**; private subnets reach AWS services via **6 VPC endpoints**: S3 gateway (free) plus interface endpoints for `ssm`, `ssmmessages`, `ec2messages`, `monitoring` (CloudWatch metrics), and `logs` (CloudWatch Logs) |
| 2nd | `compute` | Private S3 bucket for artifacts; a `null_resource` runs `pip3 download` locally and uploads the Python wheels **and the `node_exporter` binary** to S3; security group for port 8000; IAM instance profile (SSM + CloudWatch + S3 read); AL2023 EC2 launch template |
| 3rd | `asg` | Auto Scaling Group; 2 EC2 instances in **private** subnets launch, pull artifacts from S3 via the gateway endpoint, then start the `techstream` (Flask) and `node_exporter` systemd units |
| 4th | `alarms` | **Two** SNS topics (`-alerts`, `-insights`), 3 CloudWatch alarms (ErrorRate, CPU, Memory), email subscriptions on the alerts topic |
| 5th | `lambda` | Remediator Lambda, RCA Summariser Lambda, EventBridge rule (filters `state=ALARM`), RCA subscription to the insights topic, 4 CloudWatch log groups |
| 6th | `devops_guru` | DevOps Guru resource collection monitoring the CloudFormation stack, with the insights topic as its notification channel |
| 7th | `monitoring` | IAM role (EC2 service discovery), security group, **Amazon Linux 2023** t3.small EC2 instance, Elastic IP — user-data installs Prometheus (binary) and Grafana (RPM) as systemd services (no Docker) |

### 4d — Save the outputs

When apply finishes, Terraform prints the outputs. **Copy these to a notepad now** — you will need them throughout the lab:

```
grafana_url                = "http://54.X.X.X:3000"
prometheus_url             = "http://54.X.X.X:9090"
monitoring_instance_id     = "i-XXXXXXXXXXXXXXXXX"
asg_name                   = "TechStream-prod-ASG"
sns_topic_arn              = "arn:aws:sns:eu-west-1:123456789012:TechStream-prod-alerts"
remediator_function_arn    = "arn:aws:lambda:eu-west-1:123456789012:function:TechStream-prod-Remediator"
rca_summariser_function_arn= "arn:aws:lambda:eu-west-1:123456789012:function:TechStream-prod-RCASummariser"
vpc_id                     = "vpc-XXXXXXXXXXXXXXXXX"
```

If you need to see the outputs again at any time:

```bash
terraform output
```

### 4e — Confirm SNS subscription emails

Check your inbox now. You will have received **two emails** with subject  
**"AWS Notification – Subscription Confirmation"** — one for the on-call address  
and one for the incidents address.

Click **Confirm subscription** in each email.

> If you skip this, CloudWatch alarm notifications and DevOps Guru insights will be
> dropped silently. The Lambda remediation via EventBridge still works — but you
> will not receive the emails.

---

## Task 5 — Wait for the Monitoring EC2 to Bootstrap

The monitoring EC2 runs **Amazon Linux 2023**. The user-data script downloads the
Prometheus binary and the Grafana RPM and starts both as **systemd services** (no
Docker). This takes **3–5 minutes** after the instance reaches `running` state.

### 5a — Check instance status

```bash
MONITORING_ID=$(terraform output -raw monitoring_instance_id)

aws ec2 describe-instance-status \
  --instance-ids "$MONITORING_ID" \
  --region eu-west-1 \
  --query 'InstanceStatuses[0].{Instance:InstanceStatus.Status,System:SystemStatus.Status}'
```

**Expected (may take 2 minutes to reach this state):**
```json
{
    "Instance": "ok",
    "System": "ok"
}
```

### 5b — Verify SSM is online then check the Prometheus + Grafana services

First confirm the SSM agent is registered (it is preinstalled on AL2023):

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$MONITORING_ID" \
  --region eu-west-1 \
  --query "InstanceInformationList[0].PingStatus" \
  --output text
```

**Expected:** `Online`

> If it returns `None`, wait 2 minutes and retry. The SSM agent starts at the very
> beginning of user-data; the Prometheus/Grafana installs run after it.

Once SSM is online, check that both services are active:

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$MONITORING_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl is-active prometheus grafana-server"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

sleep 5

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$MONITORING_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent' \
  --output text
```

**Expected:**
```
active
active
```

If either service is not active, check the user-data log:

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$MONITORING_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["tail -50 /var/log/cloud-init-output.log"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

sleep 5

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$MONITORING_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent' \
  --output text
```

### 5c — Confirm Prometheus is discovering app instances

Prometheus runs two EC2-service-discovery jobs over the ASG: `techstream_app` (the Flask
app on :8000) and `node` (node_exporter on :9100). Both should appear as healthy.

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$MONITORING_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["curl -s localhost:9090/api/v1/targets | python3 -c \"import sys,json; [print(t[\\\"labels\\\"][\\\"job\\\"], t[\\\"health\\\"]) for t in json.load(sys.stdin)[\\\"data\\\"][\\\"activeTargets\\\"]]\""]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

sleep 5

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$MONITORING_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent' \
  --output text
```

**Expected:** four healthy targets — two per instance, one for each job:
```
techstream_app up
techstream_app up
node up
node up
```

> If targets show `down`, the app EC2s may still be bootstrapping. Wait 3 minutes and
> retry — user-data on app instances syncs the wheels and node_exporter from S3 and
> installs them before starting the `techstream` and `node_exporter` services.

---

## Task 6 — Verify All System Components

Run each check in order. Do not proceed to chaos until all checks pass.

### 6.1 — EC2 instances are InService

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names TechStream-prod-ASG \
  --region eu-west-1 \
  --query 'AutoScalingGroups[0].Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}'
```

**Expected:** two entries, both `"LifecycleState": "InService"` and `"HealthStatus": "Healthy"`.

Copy one instance ID (e.g. `i-0abc123def456`) — you will need it for the next check.

### 6.2 — Flask app is running

The EC2 instances are in private subnets. Use SSM to run commands on them:

```bash
# Replace i-XXXXXXXXXXXXXXXXX with your actual instance ID
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl is-active techstream && curl -s localhost:8000/api/v1/health"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

echo "Command ID: $CMD_ID"
sleep 10

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent'
```

**Expected:**
```
active
{"service":"techstream-ingest","status":"ok","version":"1.0.0"}
```

### 6.2b — node_exporter is running

Each app instance also runs node_exporter on port 9100 (host CPU/memory metrics for
Prometheus). Confirm it is active and serving metrics:

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl is-active node_exporter && curl -s localhost:9100/metrics | head -1"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

sleep 10

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent'
```

**Expected:** `active` followed by a `# HELP ...` Prometheus comment line.

### 6.3 — CloudWatch alarms are in OK state

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix TechStream-prod \
  --region eu-west-1 \
  --query 'MetricAlarms[*].{Alarm:AlarmName,State:StateValue}'
```

**Expected:**
```json
[
  {"Alarm": "TechStream-prod-ErrorRate-High", "State": "OK"},
  {"Alarm": "TechStream-prod-CPU-High",       "State": "OK"},
  {"Alarm": "TechStream-prod-Memory-High",    "State": "OK"}
]
```

> Alarms show `INSUFFICIENT_DATA` for the first 5–10 minutes while CloudWatch
> collects the first data points. This is normal. Wait and re-run.

### 6.4 — EventBridge rule is active

```bash
aws events describe-rule \
  --name TechStream-prod-AlarmToRemediation \
  --region eu-west-1 \
  --query '{State:State}'
```

**Expected:** `"State": "ENABLED"`

### 6.5 — Lambda functions are active

```bash
aws lambda list-functions \
  --region eu-west-1 \
  --query 'Functions[?starts_with(FunctionName, `TechStream`)].FunctionName'
```

**Expected:**
```json
[
  "TechStream-prod-Remediator",
  "TechStream-prod-RCASummariser"
]
```

> `list-functions` does not expose a `State` field — that is only returned by `get-function`. Seeing both function names in the list confirms they are deployed.

### 6.6 — Grafana is reachable

```bash
GRAFANA_URL=$(terraform output -raw grafana_url)

curl -s -o /dev/null -w "HTTP status: %{http_code}\n" \
  "$GRAFANA_URL/api/health"
```

**Expected:** `HTTP status: 200`

> If you get `Connection refused`, Grafana is still starting. Wait 2 minutes and retry.
> The Elastic IP is assigned immediately, but Grafana takes ~60 seconds to start after
> the RPM installs.

---

## Task 7 — Explore the Grafana Dashboard

1. Open the `grafana_url` from your saved outputs in a browser (`http://<EIP>:3000`)
2. Log in with username `admin` and the password you set in `terraform.tfvars`
3. In the left sidebar click the **grid icon (Dashboards)**
4. Open the **TechStream** folder → click **TechStream Golden Signals**

You will see 6 panels refreshing every 15 seconds. All are backed by the single
Prometheus datasource (CPU and memory come from node_exporter via the `node` job):

| Panel | Source | What to look for at baseline |
|-------|--------|------------------------------|
| Latency (p50 / p95 / p99) | Prometheus | p50 < 100 ms, all lines flat and low |
| Traffic (req/s by endpoint) | Prometheus | Low and steady (background health checks only) |
| Error Rate (5xx %) | Prometheus | Green — below 1 % |
| Saturation (CPU % per instance) | Prometheus (node_exporter) | Green — below 30 % |
| Error Count by Status | Prometheus | Near zero |
| Memory Usage % | Prometheus (node_exporter) | Stable, below 60 % |

**Verify the Prometheus datasource:**
- Click the gear icon → **Data Sources** → click **Prometheus** (the only datasource, pointing at `http://localhost:9090`) → scroll down → **Save & Test**
- Should return: `Data source connected and labels found`

**Keep this browser tab open** — you will watch it change during the chaos phase.

---

## Task 8 — Inject a Fault (http_500 scenario)

This task runs the HTTP 500 flood scenario. `chaos.py` sends 50 concurrent malformed
POST requests per second to the Flask app at `localhost:8000`, which returns a 500 for
every malformed payload and drives the error rate above the 5 % alarm threshold.

The app fleet is private — there is **no ALB or public endpoint to hit from your laptop**.
Instead, you stage `chaos.py` onto an InService app instance and run it there over SSM,
targeting `localhost:8000`. (For a fully automated version of this, skip to Task 12 —
`verify_healing.sh` does all of this for you.)

### 8a — Pick a target instance

Reuse the `$INSTANCE_ID` you captured in Task 6.1 (any InService instance works), or
discover one now:

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names TechStream-prod-ASG \
  --region eu-west-1 \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' \
  --output text)

echo "Target instance: $INSTANCE_ID"
```

### 8b — Open monitoring terminals

Open **three terminal windows** before starting the chaos:

**Terminal 1 — stream the remediation audit log:**
```bash
aws logs tail /techstream/remediation-events \
  --follow \
  --region eu-west-1
```
This starts empty. An entry will appear the moment the Lambda fires.

**Terminal 2 — watch alarm state (runs a check every 15 seconds):**
```bash
while true; do
  echo -n "$(date -u +%H:%M:%S)  "
  aws cloudwatch describe-alarms \
    --alarm-name-prefix TechStream-prod-ErrorRate \
    --region eu-west-1 \
    --query 'MetricAlarms[0].StateValue' \
    --output text
  sleep 15
done
```

**Terminal 3 — stage chaos.py onto the instance, then run http_500 over SSM:**

First ship the script to the instance (the fleet has no internet, so we base64-encode
and decode it through SSM):

```bash
CHAOS_B64=$(base64 -w0 chaos/chaos.py 2>/dev/null || base64 chaos/chaos.py | tr -d '\n')

aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "{\"commands\":[\"echo '$CHAOS_B64' | base64 -d > /tmp/chaos.py && echo staged\"]}" \
  --region eu-west-1 \
  --query 'Command.CommandId' --output text
```

Then run the http_500 scenario on the instance, targeting the local Flask app:

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["python3.11 /tmp/chaos.py --scenario http_500 --target localhost:8000 --region eu-west-1 --duration 180"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' --output text
```

The script logs progress to the `/techstream/chaos-events` CloudWatch log group. Its
console output (visible via `get-command-invocation` once the command finishes) looks like:
```
[http_500] elapsed=177s remaining  errors=412   total=415
[http_500] elapsed=147s remaining  errors=1247  total=1252
[http_500] elapsed=117s remaining  errors=2083  total=2090
```

### 8c — Watch the Grafana dashboard change

Switch to your browser. Within 60 seconds of chaos starting:

- **Error Rate %** panel turns yellow, then red (crosses 5 %)
- **Traffic req/s** spikes sharply upward
- **Latency** may increase slightly as the app handles load

Take note of the peak error rate. It will be in the 40–50 % range.

---

## Task 9 — Observe Self-Healing

### What happens — the exact sequence

**~T+2 minutes** — CloudWatch evaluates the alarm. Two consecutive 1-minute periods
with error rate > 5 % causes the alarm to fire:

```
Terminal 2:
10:15:02  OK
10:15:17  ALARM   ←── alarm fires here
```

**~T+2 minutes + a few seconds** — EventBridge delivers the alarm state-change event
to the Remediator Lambda. This is the **single** remediation trigger: the rule filters
to `state=ALARM`, so the Lambda fires exactly once per alarm and never on the OK
recovery. (The remediator is intentionally **not** subscribed to SNS, which would
otherwise double-invoke it on ALARM and wrongly remediate on the OK notification.)

The Lambda runs its decision logic from [lambda/remediator/handler.py](../lambda/remediator/handler.py):

```python
if len(in_service_instances) < desired_capacity:
    # Instance count is below desired — something crashed
    asg.set_desired_capacity(DesiredCapacity=desired + 2)   # scale-out
    action = 'scale_out'
else:
    # All instances healthy but service is misbehaving — restart it
    ssm.send_command(
        InstanceIds=instance_ids,
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': ['sudo systemctl restart techstream && sleep 5 && systemctl is-active techstream']}
    )
    action = 'service_restart'
```

Since all 2 instances are InService, it takes the **restart** path.

**~T+2.5 minutes** — Terminal 1 shows the audit log entry:

```json
{
  "timestamp": "2026-06-22T10:15:34Z",
  "alarm_name": "TechStream-prod-ErrorRate-High",
  "action_taken": "service_restart",
  "result": "success",
  "duration_ms": 3241
}
```

**~T+3 minutes** — Flask restarts on both instances (~5 seconds per instance via SSM).
The 500 errors stop. CloudWatch evaluates two clean 1-minute periods.

**~T+4 minutes** — Alarm transitions back to OK:

```
Terminal 2:
10:17:32  ALARM
10:17:47  OK     ←── system healed
```

The Grafana Error Rate panel turns green.

### Confirm the Lambda was invoked

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=TechStream-prod-Remediator \
  --start-time $(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 1200 \
  --statistics Sum \
  --region eu-west-1 \
  --query 'Datapoints[0].Sum'
```

**Expected:** `1.0` — one Lambda invocation for this chaos run.

### Confirm the SSM restart ran

```bash
aws ssm list-command-invocations \
  --region eu-west-1 \
  --filter key=DocumentName,value=AWS-RunShellScript \
  --query 'CommandInvocations[0].{Status:Status,InstanceId:InstanceId,Document:DocumentName}' \
  --output json
```

**Expected:** `"Status": "Success"`.

---

## Task 10 — Read the AI Root-Cause Analysis Email

Amazon DevOps Guru analyses the anomaly independently of the EventBridge/Lambda path.
It correlates CloudWatch metrics, alarm history, and ASG events to generate a
structured insight, then publishes it to the **dedicated `TechStream-prod-insights`
SNS topic** (separate from the `-alerts` topic that drives the alarm/OK emails).

The **RCA Summariser Lambda** is subscribed **only** to that insights topic — so it is
never invoked on routine alarm notifications, and it also guards against any non-insight
message it might receive. When it receives a DevOps Guru insight, it:

1. Extracts the insight JSON from the SNS message (and skips it if it is not an insight)
2. Builds a structured prompt (see [lambda/rca_summariser/handler.py](../lambda/rca_summariser/handler.py))
3. Calls `bedrock:InvokeModel` with Claude Sonnet (`anthropic.claude-sonnet-4-6`)
4. Formats the JSON response as an HTML email table
5. Attaches the raw insight JSON as a file (`insight_export.json`)
6. Sends a raw SES email to `incidents_email` (To) and `oncall_email` (Cc)
7. Publishes a `bedrock_available` metric to the `TechStream/RCA` namespace

**Check your `incidents_email` inbox** for a message with subject:
```
[TechStream RCA] <InsightId> | HIGH | Errors anomaly
```

The HTML email contains five fields. What you see depends on whether Bedrock was available:

**With Bedrock (AI-generated summary):**

| Field | Example content |
|-------|----------------|
| Root Cause | Flood of malformed POST requests to /api/v1/ingest caused 500 errors |
| Leading Signal | Errors |
| Remediation Taken | `techstream` service restarted via SSM Run Command on 2 instances |
| Customer Impact | Ingest endpoint unavailable for ~3 minutes |
| Follow-up | Add request-rate limiting; return 400 not 500 for malformed payloads |

**Without Bedrock (SCP-blocked — DCE accounts):**

The email shows a yellow banner: *"Bedrock unavailable in this environment — summary extracted from raw DevOps Guru insight."* The five fields are populated from the raw DevOps Guru insight JSON — the anomaly description, severity, and affected resources are still accurate, just not narratively summarised by Claude. The `bedrock_available` metric is published as `0` so a permanently-broken AI path is visible in CloudWatch.

Either way, `insight_export.json` is attached — the full raw DevOps Guru payload.

**If the email has not arrived after 5 minutes**, check the RCA Lambda logs:

```bash
aws logs tail /aws/lambda/TechStream-prod-RCASummariser \
  --since 30m \
  --region eu-west-1
```

> DevOps Guru sometimes takes 10–15 minutes to publish its first insight on a new
> workspace. If it has not arrived after 15 minutes, proceed to Task 11 and check
> back later.

---

## Task 11 — Run a Second Scenario (CPU Spike)

Repeat the process with the CPU spike scenario to see the CPU alarm fire instead
of the error rate alarm.

**Terminal 1** — stream remediation log (already running, or restart it):
```bash
aws logs tail /techstream/remediation-events --follow --region eu-west-1
```

**Terminal 2** — watch the CPU alarm:
```bash
while true; do
  echo -n "$(date -u +%H:%M:%S)  "
  aws cloudwatch describe-alarms \
    --alarm-name-prefix TechStream-prod-CPU \
    --region eu-west-1 \
    --query 'MetricAlarms[0].StateValue' \
    --output text
  sleep 15
done
```

**Terminal 3** — run the `cpu_spike` scenario on the instance via SSM. `chaos.py` is
already staged at `/tmp/chaos.py` from Task 8 (re-stage it with the Task 8b base64 step
if you picked a different instance):

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["python3.11 /tmp/chaos.py --scenario cpu_spike --region eu-west-1 --duration 180"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text
```

The `cpu_spike` scenario pegs all CPUs on the instance (using `stress-ng` if present,
otherwise multiprocessing busy loops). Watch Terminal 2. The CPU alarm fires after
2 consecutive minutes above 85 %. The Remediator Lambda will again be invoked via
EventBridge, this time with
`alarm_name = TechStream-prod-CPU-High`.

> **Memory scenario:** the third scenario runs the same way — swap `--scenario cpu_spike`
> for `--scenario memory_leak` and watch `TechStream-prod-Memory-High` instead. The
> `memory_leak` scenario allocates 10 MB chunks until it crosses ~90 % memory (which the
> Flask app reports via the `mem_used_percent` CloudWatch metric).

---

## Task 12 — Automated Verification with verify_healing.sh

`verify_healing.sh` wraps the entire test cycle into a single automated script that runs
from your laptop. It **discovers an InService instance** from the ASG, ships `chaos.py` to
it over SSM, injects the `http_500` scenario against `localhost:8000`, records baseline
metrics, polls for the alarm to fire, then waits for recovery and asserts the system healed.

There is no `--alb-dns` — the script targets the instance directly via SSM. Flags:

| Flag | Default | Purpose |
|------|---------|---------|
| `--region` | `eu-west-1` | AWS region |
| `--asg-name` | `TechStream-prod-ASG` | ASG to discover an instance from |
| `--instance-id` | (auto-discovered) | Pin a specific instance instead of auto-discovering |
| `--alarm-name` | `TechStream-prod-ErrorRate-High` | Alarm to poll |

```bash
# From the repo root — requires the AWS CLI and SSM access to the instances.
# Best run from a Linux/macOS shell or AWS CloudShell (uses bash, base64, mktemp).
chmod +x chaos/verify_healing.sh

./chaos/verify_healing.sh --region eu-west-1
```

The script prints progress at each stage:

```
=== TechStream Self-Healing Verification ===
Instance : i-0abc123def4567890
Region   : eu-west-1
Alarm    : TechStream-prod-ErrorRate-High

[1/5] Shipping chaos.py to the instance via SSM...
      Staged /tmp/chaos.py
[2/5] Recording baseline 5xx error rate...
      Baseline: 0.12%
[3/5] Injecting http_500 chaos on the instance (async, 180s)...
      SSM command: 1a2b3c4d-...
[4/5] Polling for alarm trigger (max 600s)...
      t+  0s  alarm=OK               5xx=1.2%
      t+ 30s  alarm=OK               5xx=28.4%
      t+ 60s  alarm=OK               5xx=43.1%
      t+ 90s  alarm=ALARM            5xx=46.2%
      Alarm triggered — EventBridge should invoke the remediator.
[5/5] Verifying recovery...
      t+ 30s  alarm=ALARM            5xx=21.3%
      t+ 60s  alarm=ALARM            5xx=3.1%
      t+ 90s  alarm=OK               5xx=0.09%

Self-healing verified: alarm=OK and 5xx rate (0.09%) returned to baseline (0.12%).
```

Exit code `0` = PASS. Exit code `1` = the system did not heal within the wait window
(check `/techstream/remediation-events` in CloudWatch Logs). Exit code `2` = the script
could not resolve an InService instance in the ASG.

---

## Task 12b — Run the Unit Tests

The repository ships a pytest suite that runs entirely locally (no AWS calls — boto3
clients are mocked and the app's CloudWatch publisher thread is disabled). It covers the
Flask endpoints, the remediator decision logic, and the RCA summariser (including the
Bedrock-unavailable fallback).

```bash
# From the repo root
pip install -r requirements-dev.txt
pytest
```

**Expected:** `16 passed`.

These same checks run in **CI** ([.github/workflows/ci.yml](../.github/workflows/ci.yml))
on every push to `main` and on every pull request:

1. **Python unit tests** — `pytest`
2. **Terraform** — `terraform fmt -check -recursive` and `terraform validate`
3. **IaC security scan** — `tfsec` over the `terraform/` tree

---

## Task 13 — Tear Down

Destroy all AWS resources when you are done to avoid charges.

```bash
cd terraform
terraform destroy
```

Type `yes` when prompted. Terraform destroys everything in reverse dependency order.
Takes about 5 minutes.

**Estimated cost if left running 24 hours:**
| Resource | Daily cost |
|----------|-----------|
| 2× EC2 t3.medium (app) | ~$2.00 |
| 1× EC2 t3.small (monitoring) | ~$0.50 |
| 5× VPC interface endpoints × 2 AZs (ssm, ssmmessages, ec2messages, monitoring, logs) | ~$2.40 |
| S3 gateway endpoint | $0.00 (free) |
| S3 packages bucket | < $0.01 |
| Elastic IP (monitoring) | ~$0.00 (free while attached to a running instance) |
| Lambda, CloudWatch, DevOps Guru | < $0.10 |
| **Total** | **~$5.00/day** |

> There is **no ALB and no NAT Gateway**. The interface endpoints replace the NAT Gateway:
> the app instances have **zero internet route**, which is categorically better security, at
> a price comparable to (slightly above) what a single NAT Gateway would have cost. The S3
> gateway endpoint — which carries the package/wheel downloads — is free.

---

## Troubleshooting

### Monitoring EC2 services not starting

```bash
MONITORING_ID=$(terraform output -raw monitoring_instance_id)

# Pull the last 100 lines of user-data output
CMD_ID=$(aws ssm send-command \
  --instance-ids "$MONITORING_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["tail -100 /var/log/cloud-init-output.log"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

sleep 5

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$MONITORING_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent' \
  --output text
```

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `prometheus`/`grafana-server` not `active` | Prometheus binary or Grafana RPM download still running or failed | Check the cloud-init log; user-data takes 3–5 minutes on first boot |
| Prometheus up but targets `down` | App instances still bootstrapping | Wait 3–5 minutes; app user-data syncs wheels + node_exporter from S3 then starts the `techstream` and `node_exporter` services |
| SSM `None` after 10 minutes | SSM agent not yet registered | The agent is preinstalled on AL2023; check the cloud-init log and that the SSM/ssmmessages/ec2messages endpoints exist |

### `pip3 download` fails during `terraform apply`

The artifact-staging `null_resource` runs `pip3 download` on your local machine
before the EC2 instances launch. If this step fails, Terraform aborts with
`local-exec provisioner error`.

Common causes:

| Error message | Fix |
|--------------|-----|
| `Python was not found` (Windows) | Disable App Execution Aliases: Settings → Apps → Advanced app settings → App execution aliases → turn off `python3.exe` / `python.exe`. Then confirm `pip3 --version` works in Git Bash. |
| `pip3: command not found` | Run `pip3 install --upgrade pip` or install Python 3.11 and add it to PATH |
| `No matching distribution found` | One of the packages has no pre-built manylinux wheel. Try removing `--only-binary=:all:` for that package in the Terraform provisioner |
| `aws s3 sync` fails after pip succeeds | Confirm your AWS credentials are configured (`aws sts get-caller-identity`) and the S3 bucket was created |

Once fixed, re-run `terraform apply` — the `null_resource` trigger is a file hash so it
will re-execute the provisioner and upload the wheels, then continue creating the ASG.

### Prometheus targets show `down` after 5 minutes

Check the Prometheus SD config has the correct ASG name:

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids "$MONITORING_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["cat /opt/prometheus/prometheus.yml"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text)

sleep 10

aws ssm get-command-invocation \
  --command-id "$CMD_ID" \
  --instance-id "$MONITORING_ID" \
  --region eu-west-1 \
  --query 'StandardOutputContent'
```

Verify the `values` field under `tag:aws:autoscaling:groupName` matches:

```bash
terraform output asg_name
```

### CloudWatch alarms stuck in INSUFFICIENT_DATA after 15 minutes

```bash
# Verify metrics are being published from EC2
aws cloudwatch list-metrics \
  --namespace TechStream/GoldenSignals \
  --region eu-west-1
```

If this returns empty, the Flask app is not publishing metrics. Check via SSM:

```bash
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl status techstream | tail -5"]}' \
  --region eu-west-1 \
  --query 'Command.CommandId' \
  --output text
```

### Lambda invoked but action is `none`

The Lambda found no InService instances and no instances below desired. Check the ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names TechStream-prod-ASG \
  --region eu-west-1 \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Instances:Instances[*].{ID:InstanceId,State:LifecycleState}}'
```

### RCA email not arriving

```bash
# Check Lambda invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=TechStream-prod-RCASummariser \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 1800 \
  --statistics Sum \
  --region eu-west-1 \
  --query 'Datapoints[0].Sum'
```

If invocations = 0: DevOps Guru has not published an insight yet. It can take up to 15 minutes on a new workspace. This is normal.

If invocations > 0 but no email:

```bash
aws logs tail /aws/lambda/TechStream-prod-RCASummariser \
  --since 30m \
  --region eu-west-1
```

| Error | Fix |
|-------|-----|
| `AccessDeniedException: bedrock:InvokeModel` | Run the CLI invoke-model test in Task 1b — first-time Anthropic accounts need use-case approval |
| `AccessDeniedException: ses:SendEmail` | Verify all three email addresses in SES (Task 1a) |
| `MessageRejected` | Destination address is not SES-verified — verify all recipients |

### Grafana panels show "No data"

1. Click the gear icon → **Data Sources** → click **Prometheus** → **Save & Test** — should show `Data source connected and labels found`
2. If it fails, check that Prometheus is running: use the SSM check from Task 5b
3. Verify Prometheus is scraping using the SSM targets check from Task 5c — all `techstream_app` and `node` targets should show `up`. (Prometheus on :9090 is reachable only inside the VPC, so query it from the instance via SSM, not from your browser.)

---

## Lab Completion Checklist

```
[ ] Task 0   — AWS CLI configured and sts get-caller-identity returns account ID
[ ] Task 1   — Email verified in SES; Bedrock Claude Sonnet access granted
[ ] Task 2   — Explored repository structure and key files
[ ] Task 3   — terraform.tfvars filled in with real email and password
[ ] Task 4   — terraform apply completed; all 7 modules green; outputs saved
[ ] Task 4e  — SNS subscription confirmation emails clicked
[ ] Task 5   — Monitoring EC2 bootstrap complete; prometheus + grafana-server services active
[ ] Task 5   — Prometheus EC2 SD showing both techstream_app and node jobs UP (4 targets)
[ ] Task 6   — Component checks pass (EC2 InService, Flask healthy with the real JSON body, node_exporter active, alarms OK)
[ ] Task 7   — Grafana dashboard open and showing live data; Prometheus datasource green
[ ] Task 8   — chaos.py http_500 run on an instance via SSM; Error Rate panel turned red in Grafana
[ ] Task 9   — Alarm fired (ALARM state observed); Lambda audit log appeared in Terminal 1
[ ] Task 9   — Alarm returned to OK; Grafana Error Rate panel green again
[ ] Task 10  — RCA email received (Bedrock summary, or raw-insight fallback with yellow banner)
[ ] Task 11  — CPU spike (and optionally memory_leak) scenario run via SSM; alarm fired and healed
[ ] Task 12  — verify_healing.sh completed with PASS
[ ] Task 12b — pytest run locally (16 passed); CI workflow reviewed
[ ] Task 13  — terraform destroy completed; no resources remain
```
