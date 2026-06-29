#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data) 2>&1

PROM_VERSION="2.51.0"

# Retry helper for network-dependent steps so a brief egress gap at first boot
# (before the EIP attaches) does not abort the whole bootstrap under `set -e`.
retry() {
  local n=0 max=5 delay=15
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
# This instance is in a public subnet (internet via IGW), so dnf + the Grafana
# RPM + the Prometheus tarball download directly. SSM agent is preinstalled.
retry dnf install -y wget tar gzip

# ── Prometheus ────────────────────────────────────────────────────────────────
retry wget -q "https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/prom.tar.gz
tar -xzf /tmp/prom.tar.gz -C /opt/
ln -sfn "/opt/prometheus-$${PROM_VERSION}.linux-amd64" /opt/prometheus
mkdir -p /opt/prometheus/data
useradd --system --no-create-home --shell /usr/sbin/nologin prometheus || true

# Two EC2 service-discovery jobs over the same ASG:
#   techstream_app  -> Flask /metrics on :8000
#   node            -> node_exporter host metrics on :9100
# Both relabel instance_id so dashboard `by (instance_id)` aggregations join.
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

  - job_name: node
    ec2_sd_configs:
      - region: ${aws_region}
        port: 9100
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

chown -R prometheus:prometheus /opt/prometheus/ "/opt/prometheus-$${PROM_VERSION}.linux-amd64"

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
retry dnf install -y https://dl.grafana.com/oss/release/grafana-10.4.2-1.x86_64.rpm

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
Environment=GF_USERS_ALLOW_SIGN_UP=false
Environment=GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/techstream_golden_signals.json
GENV

systemctl daemon-reload
systemctl enable --now grafana-server

echo "DONE: Monitoring stack started"
