import json


def test_health_ok(app_client):
    resp = app_client.get("/api/v1/health")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["status"] == "ok"
    assert body["service"] == "techstream-ingest"


def test_status_ok(app_client):
    resp = app_client.get("/api/v1/status")
    assert resp.status_code == 200
    assert "uptime_seconds" in resp.get_json()


def test_ingest_accepts_valid_payload(app_client):
    resp = app_client.post("/api/v1/ingest", json={"event": "click", "id": 1})
    assert resp.status_code == 202
    assert resp.get_json()["received"] is True


def test_ingest_rejects_empty_payload(app_client):
    resp = app_client.post("/api/v1/ingest", data="", content_type="application/json")
    assert resp.status_code == 400


def test_ingest_malformed_triggers_500(app_client):
    # The http_500 chaos scenario relies on this exact behaviour.
    resp = app_client.post("/api/v1/ingest", json={"malformed": True})
    assert resp.status_code == 500


def test_ingest_rejects_oversized_payload(app_client):
    big = {"blob": "x" * (11 * 1024)}
    resp = app_client.post("/api/v1/ingest", json=big)
    assert resp.status_code == 413


def test_metrics_endpoint_exposes_prometheus(app_client):
    resp = app_client.get("/metrics")
    assert resp.status_code == 200
    assert b"techstream_request_total" in resp.data
