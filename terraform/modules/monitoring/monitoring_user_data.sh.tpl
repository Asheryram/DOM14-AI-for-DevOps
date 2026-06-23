#!/bin/bash
exec > /var/log/cloud-init-output.log 2>&1

# ── SSM Agent ─────────────────────────────────────────────────────────────────
snap install amazon-ssm-agent --classic
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service

# ── Docker ────────────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker

# ── Prometheus config ─────────────────────────────────────────────────────────
mkdir -p /opt/monitoring

cat > /opt/monitoring/prometheus.yml <<PROMCFG
global:
  scrape_interval: 15s
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

# ── Grafana provisioning ──────────────────────────────────────────────────────
mkdir -p /opt/monitoring/grafana/provisioning/datasources
mkdir -p /opt/monitoring/grafana/provisioning/dashboards
mkdir -p /opt/monitoring/grafana/dashboards

cat > /opt/monitoring/grafana/provisioning/datasources/prometheus.yaml <<DSCFG
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: http://prometheus:9090
    access: proxy
    isDefault: true
    editable: false
DSCFG

cat > /opt/monitoring/grafana/provisioning/dashboards/provider.yaml <<DASHPROV
apiVersion: 1
providers:
  - name: TechStream
    folder: TechStream
    type: file
    options:
      path: /var/lib/grafana/dashboards
DASHPROV

cat > /opt/monitoring/grafana/dashboards/techstream_golden_signals.json << 'DASHEOF'
${dashboard_json}
DASHEOF

# ── Docker Compose ────────────────────────────────────────────────────────────
cat > /opt/monitoring/docker-compose.yml <<COMPOSE
services:
  prometheus:
    image: prom/prometheus:v2.51.0
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - /opt/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=15d
      - --web.enable-lifecycle

  grafana:
    image: grafana/grafana:10.4.2
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${grafana_admin_password}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/techstream_golden_signals.json
    volumes:
      - grafana_data:/var/lib/grafana
      - /opt/monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - /opt/monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro

volumes:
  prometheus_data:
  grafana_data:
COMPOSE

cd /opt/monitoring
docker compose up -d

echo "DONE: Monitoring stack started"
