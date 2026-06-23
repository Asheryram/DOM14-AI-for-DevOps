#!/usr/bin/env bash
set -euo pipefail

ALB_DNS=""
REGION="eu-west-1"
NAMESPACE="TechStream/GoldenSignals"
METRIC_NAME="5xx_error_rate"
ALARM_NAME="TechStream-ErrorRate-High"
POLL_INTERVAL=30
MAX_WAIT=600
RECOVERY_TOLERANCE=1.0

while [[ $# -gt 0 ]]; do
  case $1 in
    --alb-dns)  ALB_DNS="$2"; shift 2;;
    --region)   REGION="$2";  shift 2;;
    *) shift;;
  esac
done

if [ -z "$ALB_DNS" ]; then
  echo "Usage: $0 --alb-dns <ALB_DNS> [--region us-east-1]"
  exit 2
fi

get_error_rate() {
  local val
  val=$(aws cloudwatch get-metric-statistics \
    --namespace "$NAMESPACE" \
    --metric-name "$METRIC_NAME" \
    --start-time "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2M +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 120 \
    --statistics Average \
    --region "$REGION" \
    --query 'Datapoints[0].Average' \
    --output text 2>/dev/null)
  echo "${val:-0}"
}

get_alarm_state() {
  aws cloudwatch describe-alarms \
    --alarm-names "$ALARM_NAME" \
    --region "$REGION" \
    --query 'MetricAlarms[0].StateValue' \
    --output text 2>/dev/null || echo "UNKNOWN"
}

echo "=== TechStream Self-Healing Verification ==="
echo "Target  : http://$ALB_DNS"
echo "Region  : $REGION"
echo "Alarm   : $ALARM_NAME"
echo ""

echo "[1/4] Recording baseline 5xx error rate..."
BASELINE=$(get_error_rate)
echo "      Baseline: ${BASELINE}%"

echo ""
echo "[2/4] Injecting http_500 chaos..."
python3 ./chaos.py --scenario http_500 --alb-dns "$ALB_DNS" --region "$REGION" &
CHAOS_PID=$!
echo "      Chaos PID: $CHAOS_PID"

echo ""
echo "[3/4] Polling for alarm trigger (max ${MAX_WAIT}s)..."
ELAPSED=0
ALARM_TRIGGERED=false
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  STATE=$(get_alarm_state)
  RATE=$(get_error_rate)
  printf "      t+%3ds  alarm=%-15s  5xx=%s%%\n" "$ELAPSED" "$STATE" "$RATE"
  if [ "$STATE" = "ALARM" ]; then
    ALARM_TRIGGERED=true
    echo "      Alarm triggered — Lambda remediator should fire."
    break
  fi
  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ "$ALARM_TRIGGERED" = "false" ]; then
  echo "      WARNING: alarm did not trigger within ${MAX_WAIT}s."
fi

echo ""
echo "[4/4] Waiting for chaos to end, then verifying recovery..."
wait "$CHAOS_PID" || true

RECOVERY_ELAPSED=0
while [ "$RECOVERY_ELAPSED" -lt "$MAX_WAIT" ]; do
  STATE=$(get_alarm_state)
  RATE=$(get_error_rate)
  printf "      t+%3ds  alarm=%-15s  5xx=%s%%\n" "$RECOVERY_ELAPSED" "$STATE" "$RATE"

  RECOVERED_BELOW_BASELINE=$(awk -v rate="$RATE" -v base="$BASELINE" -v tol="$RECOVERY_TOLERANCE" \
    'BEGIN { print (rate+0 <= base+0+tol) ? "yes" : "no" }')

  if [ "$STATE" = "OK" ] && [ "$RECOVERED_BELOW_BASELINE" = "yes" ]; then
    echo ""
    echo "Self-healing verified: alarm=OK and 5xx rate (${RATE}%) returned to baseline (${BASELINE}%)."
    exit 0
  fi
  sleep "$POLL_INTERVAL"
  RECOVERY_ELAPSED=$((RECOVERY_ELAPSED + POLL_INTERVAL))
done

echo ""
echo "FAIL: self-healing did not complete within ${MAX_WAIT}s."
echo "Check /techstream/remediation-events in CloudWatch Logs for details."
exit 1
