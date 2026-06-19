from flask import Flask, request, jsonify, abort
from prometheus_flask_exporter import PrometheusMetrics
from prometheus_client import Histogram, Counter
import time
import random
import json
import os
import threading
import boto3

app = Flask(__name__)
app.start_time = time.time()
metrics = PrometheusMetrics(app)
metrics.info('service_info', 'TechStream API service metadata', version='1.0.0', environment='production')

REQUEST_LATENCY = Histogram(
    'techstream_request_latency_seconds', 'Latency of HTTP requests',
    ['endpoint', 'method']
)
REQUEST_COUNT = Counter(
    'techstream_request_total', 'Request count by endpoint and method',
    ['endpoint', 'method', 'status']
)
REQUEST_ERRORS = Counter(
    'techstream_error_total', 'HTTP error count by endpoint and method',
    ['endpoint', 'method', 'status']
)

_cw_lock = threading.Lock()
_window_total = 0
_window_errors = 0


@app.before_request
def before_request():
    request.start_time = time.time()


@app.after_request
def after_request(response):
    global _window_total, _window_errors
    endpoint = request.path
    method = request.method
    duration = time.time() - getattr(request, 'start_time', time.time())
    REQUEST_LATENCY.labels(endpoint=endpoint, method=method).observe(duration)
    REQUEST_COUNT.labels(endpoint=endpoint, method=method, status=response.status_code).inc()
    if response.status_code >= 400:
        REQUEST_ERRORS.labels(endpoint=endpoint, method=method, status=response.status_code).inc()
    with _cw_lock:
        _window_total += 1
        if response.status_code >= 500:
            _window_errors += 1
    return response


@app.route('/api/v1/ingest', methods=['POST'])
def ingest():
    payload = request.get_json(silent=True)
    if not payload:
        abort(400, description='invalid JSON payload')

    if payload.get('malformed'):
        abort(500, description='simulated downstream failure')

    data_size = len(json.dumps(payload).encode('utf-8'))
    if data_size > 1024 * 10:
        abort(413, description='payload too large')

    time.sleep(random.uniform(0.05, 0.35))

    return jsonify({
        'status': 'accepted',
        'received': True,
        'processed_bytes': data_size
    }), 202


@app.route('/api/v1/health', methods=['GET'])
def health():
    return jsonify({
        'service': 'techstream-ingest',
        'status': 'ok',
        'version': '1.0.0'
    }), 200


@app.route('/api/v1/status', methods=['GET'])
def status():
    return jsonify({
        'uptime_seconds': int(time.time() - app.start_time),
        'active_endpoints': ['/api/v1/ingest', '/api/v1/health', '/api/v1/status']
    }), 200


def _cloudwatch_publisher():
    global _window_total, _window_errors
    region = os.environ.get('AWS_REGION', 'us-east-1')
    asg_name = os.environ.get('ASG_NAME', 'TechStream-Prod-ASG')
    cw = boto3.client('cloudwatch', region_name=region)
    while True:
        time.sleep(60)
        with _cw_lock:
            total = _window_total
            errors = _window_errors
            _window_total = 0
            _window_errors = 0
        if total == 0:
            continue
        error_rate = (errors / total) * 100
        try:
            cw.put_metric_data(
                Namespace='TechStream/GoldenSignals',
                MetricData=[{
                    'MetricName': '5xx_error_rate',
                    'Value': error_rate,
                    'Unit': 'Percent',
                    'Dimensions': [
                        {'Name': 'AutoScalingGroupName', 'Value': asg_name}
                    ]
                }]
            )
        except Exception:
            pass


if os.environ.get('ENABLE_CW_METRICS', 'true').lower() == 'true':
    _cw_thread = threading.Thread(target=_cloudwatch_publisher, daemon=True)
    _cw_thread.start()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
