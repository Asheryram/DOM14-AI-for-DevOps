#!/usr/bin/env bash
# Automated self-healing verification.
#
# The app ASG is private (no public ingress), so chaos runs ON an instance via
# SSM Run Command against localhost:8000. This script: discovers an InService
# instance, ships chaos.py to it, injects the http_500 scenario, then polls the
# CloudWatch alarm and the 5xx metric from here until the system heals.
set -euo pipefail

REGION="eu-west-1"
ASG_NAME="TechStream-prod-ASG"
INSTANCE_ID=""
NAMESPACE="TechStream/GoldenSignals"
METRIC_NAME="5xx_error_rate"
ALARM_NAME="TechStream-prod-ErrorRate-High"
DURATION=180
POLL_INTERVAL=30
MAX_WAIT=600
RECOVERY_TOLERANCE=1.0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)      REGION="$2";      shift 2;;
    --asg-name)    ASG_NAME="$2";    shift 2;;
    --instance-id) INSTANCE_ID="$2"; shift 2;;
    --alarm-name)  ALARM_NAME="$2";  shift 2;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

# Resolve an InService instance from the ASG if one was not supplied.
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`]|[0].InstanceId' \
    --output text 2>/dev/null)
fi

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "ERROR: could not resolve an InService instance in ASG $ASG_NAME"
  exit 2
fi

run_ssm() {
  # run_ssm "<shell command>" -> prints StandardOutputContent
  # $1 is a shell command with no double-quotes (safe to embed in JSON directly).
  local cmd="$1"
  local cid params
  params="$(mktemp)"
  printf '{"commands":["%s"]}' "$cmd" > "$params"
  cid=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "file://$params" \
    --region "$REGION" \
    --query 'Command.CommandId' --output text)
  rm -f "$params"
  aws ssm wait command-executed --command-id "$cid" --instance-id "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" --region "$REGION" \
    --query 'StandardOutputContent' --output text
}

get_error_rate() {
  local val
  val=$(aws cloudwatch get-metric-statistics \
    --namespace "$NAMESPACE" --metric-name "$METRIC_NAME" \
    --start-time "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2M +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 120 --statistics Average --region "$REGION" \
    --query 'Datapoints[0].Average' --output text 2>/dev/null)
  [ "$val" = "None" ] && val=""
  echo "${val:-0}"
}

get_alarm_state() {
  aws cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --region "$REGION" \
    --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "UNKNOWN"
}

echo "=== TechStream Self-Healing Verification ==="
echo "Instance : $INSTANCE_ID"
echo "Region   : $REGION"
echo "Alarm    : $ALARM_NAME"
echo ""

echo "[1/5] Shipping chaos.py to the instance via SSM..."
CHAOS_B64=$(base64 -w0 "$SCRIPT_DIR/chaos.py" 2>/dev/null || base64 "$SCRIPT_DIR/chaos.py" | tr -d '\n')
run_ssm "echo '$CHAOS_B64' | base64 -d > /tmp/chaos.py && echo staged" >/dev/null
echo "      Staged /tmp/chaos.py"

echo "[2/5] Recording baseline 5xx error rate..."
BASELINE=$(get_error_rate)
echo "      Baseline: ${BASELINE}%"

echo "[3/5] Injecting http_500 chaos on the instance (async, ${DURATION}s)..."
CHAOS_CID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "{\"commands\":[\"python3.11 /tmp/chaos.py --scenario http_500 --target localhost:8000 --region $REGION --duration $DURATION\"]}" \
  --region "$REGION" --query 'Command.CommandId' --output text)
echo "      SSM command: $CHAOS_CID"

echo "[4/5] Polling for alarm trigger (max ${MAX_WAIT}s)..."
ELAPSED=0; ALARM_TRIGGERED=false
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  STATE=$(get_alarm_state); RATE=$(get_error_rate)
  printf "      t+%3ds  alarm=%-15s  5xx=%s%%\n" "$ELAPSED" "$STATE" "$RATE"
  if [ "$STATE" = "ALARM" ]; then
    ALARM_TRIGGERED=true
    echo "      Alarm triggered — EventBridge should invoke the remediator."
    break
  fi
  sleep "$POLL_INTERVAL"; ELAPSED=$((ELAPSED + POLL_INTERVAL))
done
[ "$ALARM_TRIGGERED" = "false" ] && echo "      WARNING: alarm did not trigger within ${MAX_WAIT}s."

echo "[5/5] Verifying recovery..."
RECOVERY_ELAPSED=0
while [ "$RECOVERY_ELAPSED" -lt "$MAX_WAIT" ]; do
  STATE=$(get_alarm_state); RATE=$(get_error_rate)
  printf "      t+%3ds  alarm=%-15s  5xx=%s%%\n" "$RECOVERY_ELAPSED" "$STATE" "$RATE"
  RECOVERED=$(awk -v r="$RATE" -v b="$BASELINE" -v t="$RECOVERY_TOLERANCE" 'BEGIN{print (r+0<=b+0+t)?"yes":"no"}')
  if [ "$STATE" = "OK" ] && [ "$RECOVERED" = "yes" ]; then
    echo ""
    echo "Self-healing verified: alarm=OK and 5xx rate (${RATE}%) returned to baseline (${BASELINE}%)."
    exit 0
  fi
  sleep "$POLL_INTERVAL"; RECOVERY_ELAPSED=$((RECOVERY_ELAPSED + POLL_INTERVAL))
done

echo ""
echo "FAIL: self-healing did not complete within ${MAX_WAIT}s."
echo "Check /techstream/remediation-events in CloudWatch Logs for details."
exit 1
