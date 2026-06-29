#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data) 2>&1

# Retry helper — these instances are private (no NAT); transient dnf/S3 hiccups
# under `set -e` must not silently abort the whole bootstrap.
retry() {
  local n=0 max=5 delay=10
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$max" ]; then
      echo "command failed after $max attempts: $*" >&2
      return 1
    fi
    echo "attempt $n failed: $* - retrying in $${delay}s" >&2
    sleep "$delay"
  done
}

# ── System packages ───────────────────────────────────────────────────────────
# AL2023's default `python3` is 3.9; the staged wheels are built for cp311, so we
# install and use python3.11 explicitly to keep the ABI consistent end to end.
# dnf reaches the in-region AL2023 repo via the S3 gateway endpoint (no NAT).
retry dnf install -y python3.11 python3.11-pip tar gzip

# AWS CLI v2 is not preinstalled on AL2023; install it from the repo if absent.
command -v aws >/dev/null 2>&1 || retry dnf install -y awscli-2

# ── Python wheels from S3 (via VPC gateway endpoint — no internet needed) ─────
mkdir -p /tmp/ts_wheels
retry aws s3 sync "s3://${packages_bucket}/wheels/" /tmp/ts_wheels/ --region ${aws_region}
python3.11 -m pip install --no-index --find-links /tmp/ts_wheels /tmp/ts_wheels/*.whl

# Fail fast and visibly if the dependency set is incomplete or ABI-mismatched.
python3.11 -c "import flask, gunicorn, psutil, boto3, prometheus_flask_exporter"

# ── node_exporter (host CPU/memory metrics scraped by Prometheus) ─────────────
NE="node_exporter-${node_exporter_version}.linux-amd64"
mkdir -p /tmp/ne
retry aws s3 cp "s3://${packages_bucket}/node_exporter/$${NE}.tar.gz" "/tmp/ne/$${NE}.tar.gz" --region ${aws_region}
tar -xzf "/tmp/ne/$${NE}.tar.gz" -C /tmp/ne
install -m 0755 "/tmp/ne/$${NE}/node_exporter" /usr/local/bin/node_exporter
useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter || true

cat > /etc/systemd/system/node_exporter.service <<NESVC
[Unit]
Description=Prometheus node_exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
NESVC

# ── Flask application ─────────────────────────────────────────────────────────
mkdir -p /opt/techstream
echo "${app_py_b64}" | base64 -d > /opt/techstream/app.py

# Single worker + threads: keeps Prometheus /metrics and the CloudWatch publisher
# consistent (one process, one in-memory metric registry) while still handling
# concurrent chaos load via the thread pool.
cat > /etc/systemd/system/techstream.service <<APPSVC
[Unit]
Description=TechStream Flask Ingestion API
After=network.target

[Service]
WorkingDirectory=/opt/techstream
Environment=AWS_REGION=${aws_region}
Environment=ASG_NAME=${name_prefix}-ASG
Environment=ENABLE_CW_METRICS=true
ExecStart=/usr/bin/python3.11 -m gunicorn \
  --bind 0.0.0.0:8000 \
  --workers 1 \
  --threads 8 \
  --timeout 60 \
  app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
APPSVC

systemctl daemon-reload
systemctl enable --now node_exporter
systemctl enable --now techstream

echo "DONE: TechStream app + node_exporter started"
