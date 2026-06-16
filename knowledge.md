## TechStream Self-Healing System — Full Prompt (Email Notifications)

---

### Context & real-world framing

> You are a senior DevOps engineer at **TechStream**, a SaaS video analytics company serving ~2,000 enterprise clients. Your platform processes ~4M API calls per day. Last quarter, three production incidents each took over 90 minutes to resolve because on-call engineers were paged after the damage was done. Leadership has mandated reducing MTTR to under 10 minutes. Your mission: build a self-healing observability system that detects, diagnoses, and remediates the most common failure classes before a human is ever woken up.

---

### Deliverable prompt

---

**Prompt:**

> You are a senior DevOps/SRE engineer at TechStream. We run a Python Flask web API deployed on an EC2 Auto Scaling Group (ASG) behind an Application Load Balancer (ALB), in AWS `us-east-1`. We process video analytics events for enterprise clients and cannot afford sustained outages.
>
> **Your objective:** Design and implement a full "self-healing" production system end-to-end. Walk through each phase below in order, providing infrastructure-as-code (Terraform), scripts, and configuration files.

---

### Phase 1 — Instrument Golden Signal monitoring

Deploy a Prometheus scrape config and Grafana dashboard for our Flask app that covers all four Golden Signals:

- **Latency**: p50, p95, p99 of request duration using `prometheus_flask_exporter`
- **Traffic**: requests per second, broken down by endpoint and HTTP method
- **Errors**: HTTP 4xx and 5xx rates as a percentage of total traffic
- **Saturation**: EC2 CPU and memory utilisation per ASG instance

Provide the following:

1. `app.py` — Flask app with `prometheus_flask_exporter` middleware wired in, exposing `/metrics` for Prometheus scraping.

2. `prometheus.yml` — Scrape config targeting the EC2 instances in the ASG via the `ec2_sd_configs` service discovery block. Set `scrape_interval: 15s`.

3. `grafana_dashboard.json` — A fully importable Grafana dashboard JSON with four panels arranged in a 2×2 grid (all visible without scrolling):
   - Panel 1: Latency — time series showing p50, p95, p99
   - Panel 2: Traffic — requests/sec by endpoint
   - Panel 3: Error rate — 5xx % of total as a stat panel with threshold colouring (green < 2%, yellow 2–5%, red > 5%)
   - Panel 4: Saturation — CPU % per instance as a gauge

4. `cloudwatch-agent.json` — CloudWatch agent config that mirrors all four Golden Signal metrics into CloudWatch under the namespace `TechStream/GoldenSignals` using metric dimensions `Endpoint`, `Method`, and `InstanceId`. This runs in parallel to Prometheus so we have redundancy.

---

### Phase 2 — Build the chaos injection script

Write `chaos/chaos.py` (Python, uses `requests`, `threading`, `boto3`, and `subprocess`) that simulates three realistic production failure scenarios:

**Scenario 1 — HTTP 500 flood** (`--scenario http_500`):
Spawn 200 concurrent threads each firing POST requests to `http://<ALB_DNS>/api/v1/ingest` for 3 minutes with a malformed JSON payload that triggers a 500 on the app side. The error rate must exceed 10% to guarantee the CloudWatch alarm fires.

**Scenario 2 — CPU saturation** (`--scenario cpu_spike`):
Use `subprocess` to call `stress-ng --cpu 4 --timeout 120s` on the EC2 instance, pushing CPU above 85% for 2 minutes. If `stress-ng` is unavailable, fall back to pure Python: spin up `multiprocessing.cpu_count()` processes each running a tight `while True` math loop for 120 seconds.

**Scenario 3 — Memory leak simulation** (`--scenario memory_leak`):
Every 500ms, append a 10MB `bytearray` to a list. Log current memory usage via `psutil` each iteration. Once process memory exceeds 90% of total system RAM, release the list and log recovery. Repeat the cycle twice.

All three scenarios must:
- Write a structured `chaos_start` JSON log to CloudWatch Logs under `/techstream/chaos-events` at start, and a `chaos_end` log at finish, both containing fields: `scenario`, `timestamp`, `target_endpoint`, `expected_signal_impact`.
- Accept `--alb-dns` and `--region` as CLI flags with sensible defaults.
- Print a live progress line to stdout every 10 seconds showing elapsed time and current simulated error count or CPU/memory reading.

---

### Phase 3 — Alerting pipeline and automated remediation

Set up the full alerting-to-remediation pipeline using CloudWatch + SNS + EventBridge + Lambda + SES.

**Step 1 — CloudWatch Alarm**

Create a Terraform resource for a CloudWatch Alarm named `TechStream-ErrorRate-High`:
- Metric: `5xx_error_rate` from namespace `TechStream/GoldenSignals`
- Threshold: > 5%
- Evaluation: 2 consecutive datapoints over 2-minute periods (so alarm fires after 4 minutes of sustained errors)
- `TreatMissingData`: `breaching`
- `ComparisonOperator`: `GreaterThanThreshold`

**Step 2 — SNS topic and email subscriptions**

Create an SNS topic `techstream-alerts` and subscribe two email addresses via `aws_sns_topic_subscription` Terraform resources:
- `oncall@techstream.io` — primary on-call engineer
- `incidents@techstream.io` — shared team inbox for audit trail

Both use `Protocol: email`. Add a Terraform `null_resource` with a `local-exec` provisioner that prints a reminder: `"ACTION REQUIRED: Confirm SNS email subscriptions before testing."` Add the CloudWatch Alarm as a producer to this SNS topic via `alarm_actions`.

**Step 3 — EventBridge rule**

Create an EventBridge rule that matches:
```json
{
  "source": ["aws.cloudwatch"],
  "detail-type": ["CloudWatch Alarm State Change"],
  "detail": {
    "state": { "value": ["ALARM"] },
    "alarmName": ["TechStream-ErrorRate-High"]
  }
}
```
Target: the remediation Lambda. Pass the full event payload as-is.

**Step 4 — Lambda Remediator** (`lambda/remediator.py`)

Write the full Lambda function with this logic:

```
1. Parse the incoming EventBridge event to extract alarm name and state change time.
2. Call ec2:DescribeAutoScalingGroups for ASG named "TechStream-Prod-ASG".
3. If InService instance count < desired capacity:
     → Call autoscaling:SetDesiredCapacity to increase by 2.
     → Set action = "scale_out"
   Else:
     → Call ssm:SendCommand with document "AWS-RunShellScript"
       targeting all InService instances, running:
       "sudo systemctl restart flask-app && sleep 5 && systemctl is-active flask-app"
     → Set action = "service_restart"
4. Publish a CloudWatch custom metric:
     Namespace: TechStream/Remediation
     MetricName: remediation_action
     Dimensions: Action=<action>, Result=<success|failure>
5. Write a structured JSON log to CloudWatch Logs /techstream/remediation-events:
     { timestamp, alarm_name, instances_before, action_taken, instances_after, duration_ms }
6. Send a notification email via SES:
     From: devops-guru@techstream.io
     To: incidents@techstream.io
     Subject: "[TechStream AUTO-REMEDIATION] <action> triggered — <timestamp>"
     Body (HTML):
       - Action taken
       - Instance count before and after
       - Alarm that triggered it
       - Link to CloudWatch dashboard
       - Footer: "This was an automated action. No engineer intervention was required."
```

**Step 5 — IAM role for the remediator Lambda**

Provide a least-privilege IAM policy document as a Terraform `aws_iam_policy` that grants:
- `autoscaling:DescribeAutoScalingGroups`, `autoscaling:SetDesiredCapacity`
- `ssm:SendCommand`, `ssm:GetCommandInvocation` scoped to `TechStream-Prod-ASG` instances
- `cloudwatch:PutMetricData` scoped to namespace `TechStream/Remediation`
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` for `/techstream/remediation-events`
- `ses:SendEmail`, `ses:SendRawEmail` scoped to `arn:aws:ses:us-east-1:<account-id>:identity/techstream.io`

---

### Phase 4 — AI-powered root cause analysis

**Step 1 — Enable Amazon DevOps Guru**

Provide a Terraform resource block to enable DevOps Guru with `CLOUD_FORMATION` resource collection type scoped to the stack named `TechStream-Prod`. Connect DevOps Guru's notification channel to the SNS topic `techstream-alerts` created in Phase 3 so anomaly insights also trigger email to `incidents@techstream.io`.

**Step 2 — Trigger and export an insight**

After enabling DevOps Guru, run `chaos.py --scenario http_500`. Wait 5–10 minutes. Then export the insight using the AWS CLI:

```bash
aws devops-guru list-insights \
  --status-filter '{"Any":{"StartTimeRange":{"FromTime":"<START>","ToTime":"<END>"},"Type":"REACTIVE"}}' \
  --region us-east-1 \
  --output json > insight_export.json
```

Write a Python helper script `scripts/parse_insight.py` that reads `insight_export.json` and prints a formatted summary table to stdout showing:
- `InsightId`
- `Name`
- `Severity`
- `Status`
- `AnomalyTimeRange` (start → end, human-readable)
- Top correlated anomaly metric name and its deviation magnitude

**Step 3 — Bedrock RCA summariser Lambda** (`lambda/rca_summariser.py`)

Write a Lambda triggered by the DevOps Guru SNS notification. It must:

1. Parse the SNS message body to extract the DevOps Guru insight JSON.

2. Call `bedrock-runtime` with model `anthropic.claude-sonnet-4-6` and this system prompt:

```
You are a senior SRE at TechStream. You receive raw AWS DevOps Guru insight JSON
and produce a concise, jargon-free incident summary for an engineering team.
Always respond in valid JSON with exactly these fields:
{
  "root_cause_summary": "<2-3 sentences>",
  "leading_golden_signal": "<Latency|Traffic|Errors|Saturation>",
  "remediation_taken": "<what the automated system did>",
  "customer_impact": "~N% of /api/v1/ingest requests failed for approximately M minutes",
  "recommended_followup": "<one actionable follow-up for the on-call engineer>"
}
```

3. Parse the Bedrock JSON response.

4. Send a rich HTML email via SES:
   - **From**: `devops-guru@techstream.io`
   - **To**: `incidents@techstream.io`
   - **CC**: `oncall@techstream.io`
   - **Subject**: `[TechStream RCA] <InsightId> | <Severity> | <leading_golden_signal> anomaly`
   - **HTML body** structured as:

```
TechStream Incident RCA — Auto-generated

Root Cause
<root_cause_summary>

Leading Golden Signal
<leading_golden_signal>

Automated Remediation Taken
<remediation_taken>

Estimated Customer Impact
<customer_impact>

Recommended Follow-up
<recommended_followup>

—
This RCA was generated automatically by TechStream DevOps Guru + Amazon Bedrock.
Review the attached insight JSON for full anomaly correlation details.
Incident dashboard: https://grafana.techstream.io/d/golden-signals
```

   - Attach the raw `insight_export.json` as a MIME multipart attachment using `ses_client.send_raw_email()` with a `MIMEMultipart('mixed')` envelope.

5. Add the IAM permission `bedrock:InvokeModel` for `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6` to the Lambda execution role.

---

### Phase 5 — End-to-end verification script

Write `scripts/verify_healing.sh` — a bash script that runs the full acceptance test automatically:

```bash
#!/usr/bin/env bash
# Usage: ./verify_healing.sh --alb-dns <ALB_DNS> --region us-east-1

# 1. Record baseline: query CloudWatch for current 5xx_error_rate (should be < 1%)
# 2. Start chaos: python3 chaos/chaos.py --scenario http_500 --alb-dns $ALB_DNS &
# 3. Poll CloudWatch every 30s until TechStream-ErrorRate-High enters ALARM state
#    → Print: "[T+Xm] Alarm triggered. Waiting for Lambda remediation..."
# 4. Poll CloudWatch Logs /techstream/remediation-events every 15s for a new log entry
#    → Print: "[T+Xm] Remediation fired: <action_taken>"
# 5. Poll CloudWatch every 30s until 5xx_error_rate drops below 1%
#    → Print: "[T+Xm] System recovered. MTTR: X minutes Y seconds"
# 6. Check SES send statistics via boto3 to confirm at least 2 emails were sent
#    (remediation notification + RCA summary)
#    → Print: "[OK] Notification emails confirmed sent."
# 7. Exit 0 if MTTR < 10 minutes, exit 1 otherwise with a failure summary.
```

---

### Suggested file structure

```
techstream-self-healing/
├── terraform/
│   ├── main.tf               # ASG, ALB, Lambda, EventBridge
│   ├── cloudwatch.tf         # Alarms, dashboards, log groups
│   ├── sns.tf                # SNS topic + email subscriptions
│   ├── ses.tf                # SES identity verification
│   ├── iam.tf                # Lambda execution roles
│   └── devops_guru.tf        # DevOps Guru resource collection
├── app/
│   ├── app.py                # Flask app with prometheus_flask_exporter
│   └── requirements.txt
├── monitoring/
│   ├── prometheus.yml        # Scrape config with ec2_sd_configs
│   ├── cloudwatch-agent.json # Golden Signals → CloudWatch
│   └── grafana_dashboard.json
├── chaos/
│   └── chaos.py              # --scenario flag, CloudWatch log writes
├── lambda/
│   ├── remediator.py         # Scale-out / SSM restart + SES alert
│   └── rca_summariser.py     # Bedrock RCA + SES rich HTML email
└── scripts/
    ├── parse_insight.py      # DevOps Guru insight formatter
    └── verify_healing.sh     # End-to-end acceptance test runner
```

---

### Acceptance criteria

| # | Criterion | Pass condition |
|---|-----------|----------------|
| 1 | Grafana dashboard loads all four Golden Signal panels | Live data within 60s of Flask app starting |
| 2 | Chaos script triggers the CloudWatch alarm | `TechStream-ErrorRate-High` enters `ALARM` within 4 minutes of `http_500` scenario start |
| 3 | SNS email delivered to on-call inbox | `oncall@techstream.io` receives alarm email within 1 minute of ALARM state |
| 4 | Lambda remediator fires | `remediation_action` metric appears in CloudWatch within 2 minutes of alarm |
| 5 | System self-heals | Error rate drops below 1% within 10 minutes — no human intervention |
| 6 | Remediation notification email sent | `incidents@techstream.io` receives the auto-remediation email with action details |
| 7 | DevOps Guru surfaces an insight | Anomaly correlating 5xx spike with CPU/memory appears within 10 minutes |
| 8 | RCA email delivered | `incidents@techstream.io` + `oncall@techstream.io` receive the Bedrock-generated HTML RCA email with insight JSON attached within 5 minutes of insight generation |
| 9 | MTTR target met | `verify_healing.sh` exits 0, confirming end-to-end resolution under 10 minutes |

---

> **Note on SES in sandbox mode**: AWS SES starts in sandbox mode — both sender and recipient addresses must be verified before emails flow. Run `aws ses verify-email-identity --email-address oncall@techstream.io` (and repeat for the other addresses) before running the chaos script. In production, request SES sending limit increases to move out of sandbox.