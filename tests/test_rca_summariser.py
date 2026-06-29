import json


def _sns_event(payload):
    return {"Records": [{"Sns": {"Message": json.dumps(payload)}}]}


def test_skips_non_insight_message(rca):
    # A CloudWatch alarm notification is valid JSON but must not be summarised.
    event = _sns_event({"AlarmName": "TechStream-prod-CPU-High", "NewStateValue": "ALARM"})
    result = rca.handler(event, None)
    assert result["statusCode"] == 200
    assert "skipped" in result["body"]
    rca.ses.send_raw_email.assert_not_called()


def test_fallback_when_bedrock_unavailable(rca, monkeypatch):
    def boom(_insight):
        raise Exception("AccessDeniedException: blocked by SCP")

    monkeypatch.setattr(rca, "_invoke_bedrock", boom)
    insight = {
        "InsightId": "ins-123",
        "Severity": "HIGH",
        "Type": "Errors",
        "Anomalies": [{"Description": "5xx spike on /api/v1/ingest"}],
        "ResourceCollection": {"CloudFormation": {"StackNames": ["TechStream-Prod"]}},
    }
    result = rca.handler(_sns_event(insight), None)
    assert result["statusCode"] == 200
    rca.ses.send_raw_email.assert_called_once()
    # Fallback must record that Bedrock was unavailable (value 0).
    metric = rca.cw.put_metric_data.call_args.kwargs["MetricData"][0]
    assert metric["MetricName"] == "bedrock_available"
    assert metric["Value"] == 0


def test_success_with_bedrock(rca, monkeypatch):
    summary = {
        "root_cause_summary": "Malformed POST flood",
        "leading_golden_signal": "Errors",
        "remediation_taken": "service restart",
        "customer_impact": "ingest degraded ~3m",
        "recommended_followup": "add rate limiting",
    }
    monkeypatch.setattr(rca, "_invoke_bedrock", lambda _i: summary)
    insight = {"InsightId": "ins-9", "Severity": "HIGH", "Type": "Errors"}
    result = rca.handler(_sns_event(insight), None)
    assert result["statusCode"] == 200
    rca.ses.send_raw_email.assert_called_once()
    metric = rca.cw.put_metric_data.call_args.kwargs["MetricData"][0]
    assert metric["Value"] == 1
