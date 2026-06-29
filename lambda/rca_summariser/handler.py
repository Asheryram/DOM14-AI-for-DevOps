import os
import json
import logging
import boto3
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BEDROCK_MODEL = os.environ.get('BEDROCK_MODEL', 'anthropic.claude-sonnet-4-6')
SES_FROM = os.environ.get('SES_FROM', 'devops-guru@techstream.io')
SES_TO   = os.environ.get('SES_TO',   'incidents@techstream.io')
ONCALL   = os.environ.get('ONCALL',   'oncall@techstream.io')

SUMMARY_SCHEMA = {
    'root_cause_summary': 'string — one sentence',
    'leading_golden_signal': 'one of: Errors | Latency | Traffic | Saturation',
    'remediation_taken': 'string — what the automated system did',
    'customer_impact': 'string — estimated blast radius',
    'recommended_followup': 'string — next manual steps'
}

bedrock = boto3.client('bedrock-runtime')
ses = boto3.client('ses')
cw = boto3.client('cloudwatch')


def _publish_bedrock_metric(available):
    """Surface the silent Bedrock fallback so a permanently-broken RCA path is visible."""
    try:
        cw.put_metric_data(
            Namespace='TechStream/RCA',
            MetricData=[{
                'MetricName': 'bedrock_available',
                'Value': 1 if available else 0,
                'Unit': 'Count'
            }]
        )
    except Exception:
        logger.warning('Failed to publish bedrock_available metric', exc_info=True)


def _invoke_bedrock(insight):
    prompt = (
        'You are a DevOps incident analyst. Analyse the following AWS DevOps Guru insight JSON '
        'and return a JSON object with EXACTLY these keys (no extra keys, no markdown):\n'
        f'{json.dumps(SUMMARY_SCHEMA, indent=2)}\n\n'
        f'Insight:\n{json.dumps(insight, indent=2)}\n\n'
        'Return only the JSON object.'
    )
    body = json.dumps({
        'anthropic_version': 'bedrock-2023-05-31',
        'max_tokens': 1024,
        'messages': [{'role': 'user', 'content': prompt}]
    })
    response = bedrock.invoke_model(
        modelId=BEDROCK_MODEL,
        body=body,
        contentType='application/json',
        accept='application/json'
    )
    response_body = json.loads(response['body'].read())
    content = response_body.get('content', [])
    if not content:
        raise ValueError(f'Bedrock returned empty content (stop_reason={response_body.get("stop_reason")})')
    text = content[0].get('text', '')
    if not text:
        raise ValueError('Bedrock content[0] has no text field')
    return json.loads(text)


def handler(event, context):
    message = event['Records'][0]['Sns']['Message']
    insight = json.loads(message)

    # This Lambda subscribes only to the DevOps Guru insights topic, but guard
    # defensively: a CloudWatch alarm/OK notification is also valid JSON and must
    # not be summarised as a bogus "unknown" insight.
    if 'InsightId' not in insight or 'AlarmName' in insight:
        logger.info('Non-insight SNS message (likely CloudWatch alarm/OK) — skipping RCA')
        return {'statusCode': 200, 'body': 'skipped: not a DevOps Guru insight'}

    bedrock_available = True
    try:
        summary = _invoke_bedrock(insight)
        logger.info('Bedrock RCA generated for insight %s', insight.get('InsightId'))
    except Exception as exc:
        bedrock_available = False
        if 'AccessDenied' in type(exc).__name__ or 'AccessDenied' in str(exc):
            logger.warning('Bedrock blocked by SCP — sending raw-insight email')
        else:
            logger.exception('Bedrock invocation failed — using fallback summary')
        anomalies = insight.get('Anomalies', [])
        anomaly_desc = anomalies[0].get('Description', 'No description available') if anomalies else 'No anomalies listed'
        # DevOps Guru returns StackNames as a list of plain strings.
        stack_names = insight.get('ResourceCollection', {}).get('CloudFormation', {}).get('StackNames', [])
        resources = ', '.join(stack_names) or 'See attached JSON'
        summary = {
            'root_cause_summary': anomaly_desc,
            'leading_golden_signal': insight.get('Type', 'Errors'),
            'remediation_taken': 'See CloudWatch Logs — /techstream/remediation-events',
            'customer_impact': f"Severity: {insight.get('Severity', 'UNKNOWN')} | Resources: {resources}",
            'recommended_followup': 'Review attached insight_export.json for full details'
        }

    _publish_bedrock_metric(bedrock_available)

    msg = MIMEMultipart('mixed')
    msg['Subject'] = (
        f"[TechStream RCA] {insight.get('InsightId', 'unknown')} | "
        f"{insight.get('Severity', 'unknown')} | "
        f"{summary.get('leading_golden_signal', 'Errors')} anomaly"
    )
    msg['From'] = SES_FROM
    msg['To'] = SES_TO
    msg['Cc'] = ONCALL

    bedrock_banner = (
        '<p style="background:#fff3cd;padding:8px;border-left:4px solid #ffc107">'
        '<b>Note:</b> Bedrock unavailable in this environment — summary extracted from raw DevOps Guru insight.</p>'
        if not bedrock_available else ''
    )

    html = f"""<html><body>
<h2>TechStream Incident RCA — Auto-generated</h2>
{bedrock_banner}
<table border="0" cellpadding="6" style="border-collapse:collapse">
  <tr><td><b>Root Cause</b></td><td>{summary.get('root_cause_summary')}</td></tr>
  <tr><td><b>Leading Signal</b></td><td>{summary.get('leading_golden_signal')}</td></tr>
  <tr><td><b>Remediation Taken</b></td><td>{summary.get('remediation_taken')}</td></tr>
  <tr><td><b>Customer Impact</b></td><td>{summary.get('customer_impact')}</td></tr>
  <tr><td><b>Follow-up</b></td><td>{summary.get('recommended_followup')}</td></tr>
</table>
<hr/>
<p style="color:#666;font-size:11px">
  Generated by TechStream self-healing pipeline · Model: {BEDROCK_MODEL}
</p>
</body></html>"""

    msg.attach(MIMEText(html, 'html'))
    attachment = MIMEApplication(json.dumps(insight, indent=2).encode('utf-8'))
    attachment.add_header('Content-Disposition', 'attachment', filename='insight_export.json')
    msg.attach(attachment)

    ses.send_raw_email(
        Source=SES_FROM,
        Destinations=[SES_TO, ONCALL],
        RawMessage={'Data': msg.as_string()}
    )

    return {'statusCode': 200}
