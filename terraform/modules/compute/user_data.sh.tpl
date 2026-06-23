#!/bin/bash
set -euo pipefail

# ── System packages ───────────────────────────────────────────────────────────
dnf update -y
dnf install -y python3 python3-pip

# ── Python wheels from S3 (via VPC gateway endpoint — no internet needed) ─────
mkdir -p /tmp/ts_wheels
aws s3 sync "s3://${packages_bucket}/wheels/" /tmp/ts_wheels/ --region ${aws_region}
pip3 install /tmp/ts_wheels/*.whl

# ── Flask application ─────────────────────────────────────────────────────────
mkdir -p /opt/techstream
echo "${app_py_b64}" | base64 -d > /opt/techstream/app.py

cat > /etc/systemd/system/techstream.service <<APPSVC
[Unit]
Description=TechStream Flask Ingestion API
After=network.target

[Service]
WorkingDirectory=/opt/techstream
Environment=AWS_REGION=${aws_region}
Environment=ASG_NAME=${name_prefix}-ASG
Environment=ENABLE_CW_METRICS=true
ExecStart=/usr/bin/python3 -m gunicorn \
  --bind 0.0.0.0:8000 \
  --workers 2 \
  --timeout 60 \
  app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
APPSVC

systemctl daemon-reload
systemctl enable --now techstream
