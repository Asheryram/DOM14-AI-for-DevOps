import os
import json
import boto3
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication
from datetime import datetime

BEDROCK_MODEL = os.environ.get('BEDROCK_MODEL', 'anthropic.claude-sonnet-4-6')
SES_FROM = os.environ.get('SES_FROM', 'devops-guru@techstream.io')
SES_TO = os.environ.get('SES_TO', 'incidents@techstream.io')
ONCALL = os.environ.get('ONCALL', 'oncall@techstream.io')


def handler(event, context):
    # event is expected to be an SNS notification containing DevOps Guru insight
    message = event['Records'][0]['Sns']['Message']
    insight = json.loads(message)

    # Build prompt for Bedrock
    prompt = f"DevOps Guru insight JSON:\n{json.dumps(insight)}\nPlease summarise as JSON with the required fields."

    bedrock = boto3.client('bedrock-runtime')
    response = bedrock.invoke_model(modelId=BEDROCK_MODEL, body=prompt.encode('utf-8'))
    # The response format can vary; attempt to decode
    try:
        summary_text = response['body'].read().decode('utf-8')
        summary = json.loads(summary_text)
    except Exception:
        summary = {
            'root_cause_summary': 'Could not generate automatic summary',
            'leading_golden_signal': 'Errors',
            'remediation_taken': 'N/A',
            'customer_impact': 'Unknown',
            'recommended_followup': 'Investigate further'
        }

    # Prepare email with attachment (raw insight JSON)
    msg = MIMEMultipart('mixed')
    msg['Subject'] = f"[TechStream RCA] {insight.get('InsightId','unknown')} | {insight.get('Severity','unknown')} | {summary.get('leading_golden_signal','Errors')} anomaly"
    msg['From'] = SES_FROM
    msg['To'] = SES_TO
    msg['Cc'] = ONCALL

    html = f"""
    <html><body>
    <h2>TechStream Incident RCA — Auto-generated</h2>
    <h3>Root Cause</h3>
    <p>{summary.get('root_cause_summary')}</p>
    <h3>Leading Golden Signal</h3>
    <p>{summary.get('leading_golden_signal')}</p>
    <h3>Automated Remediation Taken</h3>
    <p>{summary.get('remediation_taken')}</p>
    <h3>Estimated Customer Impact</h3>
    <p>{summary.get('customer_impact')}</p>
    <h3>Recommended Follow-up</h3>
    <p>{summary.get('recommended_followup')}</p>
    <hr/>
    <p>This RCA was generated automatically by TechStream DevOps Guru + Amazon Bedrock.</p>
    </body></html>
    """

    part = MIMEText(html, 'html')
    msg.attach(part)

    # attach raw insight
    attachment = MIMEApplication(json.dumps(insight).encode('utf-8'))
    attachment.add_header('Content-Disposition', 'attachment', filename='insight_export.json')
    msg.attach(attachment)

    ses = boto3.client('ses')
    ses.send_raw_email(Source=SES_FROM, Destinations=[SES_TO, ONCALL], RawMessage={'Data': msg.as_string()})

    return {'statusCode': 200}
