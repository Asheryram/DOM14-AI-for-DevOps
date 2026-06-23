#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data) 2>&1

# ── SSM Agent (ensure running before anything else) ───────────────────────────
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ── System packages ───────────────────────────────────────────────────────────
dnf update -y
dnf install -y wget tar gzip

# ── Prometheus ────────────────────────────────────────────────────────────────
PROM_VERSION="2.51.0"
wget -q "https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz" \
     -O /tmp/prom.tar.gz
tar -xzf /tmp/prom.tar.gz -C /opt/
ln -sf "/opt/prometheus-$${PROM_VERSION}.linux-amd64" /opt/prometheus
mkdir -p /opt/prometheus/data
useradd --system --no-create-home --shell /bin/false prometheus || true
chown -R prometheus:prometheus /opt/prometheus

cat > /opt/prometheus/prometheus.yml <<PROMCFG
global:
  scrape_interval:     15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: techstream_app
    ec2_sd_configs:
      - region: ${aws_region}
        port: 8000
        filters:
          - name: tag:aws:autoscaling:groupName
            values:
              - ${asg_name}
    relabel_configs:
      - source_labels: [__meta_ec2_instance_id]
        target_label: instance_id
      - source_labels: [__meta_ec2_private_ip]
        target_label: private_ip
PROMCFG

cat > /etc/systemd/system/prometheus.service <<SYSD
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
ExecStart=/opt/prometheus/prometheus \
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/opt/prometheus/data \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSD

systemctl daemon-reload
systemctl enable --now prometheus

# ── Grafana ───────────────────────────────────────────────────────────────────
dnf install -y https://dl.grafana.com/oss/release/grafana-10.4.2-1.x86_64.rpm

mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<DSCFG
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: http://localhost:9090
    access: proxy
    isDefault: true
    editable: false
DSCFG

mkdir -p /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/dashboards/provider.yaml <<DASHPROV
apiVersion: 1
providers:
  - name: TechStream
    folder: TechStream
    type: file
    options:
      path: /var/lib/grafana/dashboards
DASHPROV

mkdir -p /var/lib/grafana/dashboards
echo "${dashboard_json_b64}" | base64 -d \
  > /var/lib/grafana/dashboards/techstream_golden_signals.json
chown -R grafana:grafana /var/lib/grafana/dashboards /etc/grafana/provisioning

mkdir -p /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/override.conf <<GENV
[Service]
Environment=GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_password}
Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/techstream_golden_signals.json
GENV

systemctl daemon-reload
systemctl enable --now grafana-server
