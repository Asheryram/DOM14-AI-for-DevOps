#!/usr/bin/env bash
set -euo pipefail

ALB_DNS=""
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --alb-dns) ALB_DNS="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    *) shift;;
  esac
done

if [ -z "$ALB_DNS" ]; then
  echo "Usage: $0 --alb-dns <ALB_DNS> --region us-east-1"
  exit 2
fi

echo "Recording baseline 5xx_error_rate..."
# Placeholder: user must implement AWS CLI queries for CloudWatch metrics

echo "Starting chaos (http_500)..."
python3 chaos.py --scenario http_500 --alb-dns $ALB_DNS --region $REGION &
CHAOS_PID=$!

echo "Polling for alarm and remediation... (not fully automated in this scaffold)"
wait $CHAOS_PID
echo "Chaos finished. Manual verification steps remain."
