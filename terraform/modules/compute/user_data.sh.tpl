#!/bin/bash
set -euo pipefail

# Install base packages
dnf update -y
dnf install -y python3 python3-pip wget tar gzip

# Fetch the AMP remote_write URL from SSM
AMP_URL=$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "${amp_ssm_parameter_name}" \
  --query "Parameter.Value" \
  --output text)

# ── Install Prometheus ────────────────────────────────────────────────────────
PROM_VERSION="2.51.0"
wget -q "https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz" -O /tmp/prometheus.tar.gz
tar -xzf /tmp/prometheus.tar.gz -C /opt/
ln -sf /opt/prometheus-$${PROM_VERSION}.linux-amd64 /opt/prometheus

cat > /opt/prometheus/prometheus.yml <<PROMCFG
global:
  scrape_interval: 15s

remote_write:
  - url: $${AMP_URL}
    sigv4:
      region: ${aws_region}
    queue_config:
      max_samples_per_send: 1000
      max_shards: 200
      capacity: 2500

scrape_configs:
  - job_name: techstream_flask
    static_configs:
      - targets: ['localhost:8000']
    relabel_configs:
      - target_label: instance_id
        replacement: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PROMCFG

cat > /etc/systemd/system/prometheus.service <<SYSD
[Unit]
Description=Prometheus
After=network.target

[Service]
ExecStart=/opt/prometheus/prometheus \
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/opt/prometheus/data \
  --storage.tsdb.retention.time=2h
Restart=always

[Install]
WantedBy=multi-user.target
SYSD

systemctl daemon-reload
systemctl enable --now prometheus

# ── Install TechStream app ────────────────────────────────────────────────────
pip3 install flask prometheus-flask-exporter requests boto3 psutil gunicorn

mkdir -p /opt/techstream
aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/${name_prefix}/app/source" \
  --query "Parameter.Value" \
  --output text > /opt/techstream/app.py 2>/dev/null || true

cat > /etc/systemd/system/techstream.service <<APPSVC
[Unit]
Description=TechStream Flask App
After=network.target

[Service]
WorkingDirectory=/opt/techstream
Environment=ASG_NAME=${name_prefix}-ASG
Environment=AWS_REGION=${aws_region}
Environment=ENABLE_CW_METRICS=true
ExecStart=gunicorn --bind 0.0.0.0:8000 --workers 4 --timeout 60 app:app
Restart=always

[Install]
WantedBy=multi-user.target
APPSVC

systemctl daemon-reload
systemctl enable techstream
