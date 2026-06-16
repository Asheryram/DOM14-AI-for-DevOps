from flask import Flask, request, jsonify, abort
from prometheus_flask_exporter import PrometheusMetrics, Info
from prometheus_client import Histogram, Counter, Gauge
import time
import random

app = Flask(__name__)
metrics = PrometheusMetrics(app)
metrics.info('service_info', 'TechStream API service metadata', version='1.0.0', environment='production')

REQUEST_LATENCY = Histogram('techstream_request_latency_seconds', 'Latency of HTTP requests', ['endpoint', 'method'])
REQUEST_COUNT = Counter('techstream_request_total', 'Request count by endpoint and method', ['endpoint', 'method', 'status'])
REQUEST_ERRORS = Counter('techstream_error_total', 'HTTP error count by endpoint and method', ['endpoint', 'method', 'status'])

@app.before_request
def before_request():
    request.start_time = time.time()

@app.after_request
def after_request(response):
    endpoint = request.path
    method = request.method
    duration = time.time() - getattr(request, 'start_time', time.time())
    REQUEST_LATENCY.labels(endpoint=endpoint, method=method).observe(duration)
    REQUEST_COUNT.labels(endpoint=endpoint, method=method, status=response.status_code).inc()
    if response.status_code >= 400:
        REQUEST_ERRORS.labels(endpoint=endpoint, method=method, status=response.status_code).inc()
    return response

@app.route('/api/v1/ingest', methods=['POST'])
def ingest():
    payload = request.get_json(silent=True)
    if not payload:
        abort(400, description='invalid JSON payload')

    if payload.get('malformed'):
        abort(500, description='simulated downstream failure')

    # Simulate processing delay for realistic latency distribution
    processing_delay = random.uniform(0.05, 0.35)
    time.sleep(processing_delay)

    data_size = len(str(payload).encode('utf-8'))
    if data_size > 1024 * 10:
        abort(413, description='payload too large')

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

if __name__ == '__main__':
    app.start_time = time.time()
    app.run(host='0.0.0.0', port=8000)
