import os
import json
import time
import logging
import boto3
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ASG_NAME = os.environ.get('ASG_NAME', 'TechStream-Prod-ASG')
SES_FROM = os.environ.get('SES_FROM', 'devops-guru@techstream.io')
SES_TO   = os.environ.get('SES_TO',   'incidents@techstream.io')

asg = boto3.client('autoscaling')
ssm = boto3.client('ssm')
cw  = boto3.client('cloudwatch')
logs = boto3.client('logs')
ses = boto3.client('ses')


def _publish_metric(action, result):
    cw.put_metric_data(
        Namespace='TechStream/Remediation',
        MetricData=[{
            'MetricName': 'remediation_action',
            'Dimensions': [
                {'Name': 'Action', 'Value': action},
                {'Name': 'Result', 'Value': result}
            ],
            'Value': 1,
            'Unit': 'Count'
        }]
    )


def _write_log(group, stream, entry):
    try:
        logs.create_log_group(logGroupName=group)
    except logs.exceptions.ResourceAlreadyExistsException:
        pass
    try:
        logs.create_log_stream(logGroupName=group, logStreamName=stream)
    except logs.exceptions.ResourceAlreadyExistsException:
        pass
    logs.put_log_events(
        logGroupName=group,
        logStreamName=stream,
        logEvents=[{'timestamp': int(time.time() * 1000), 'message': json.dumps(entry)}]
    )


def handler(event, context):
    alarm_name = event.get('detail', {}).get('alarmName', 'unknown')
    start = time.time()
    action = 'none'
    result = 'success'

    try:
        ag = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
        groups = ag.get('AutoScalingGroups', [])
        instances_before = []
        desired = 0
        if groups:
            group = groups[0]
            instances_before = [
                i for i in group.get('Instances', [])
                if i.get('LifecycleState') == 'InService'
            ]
            desired = group.get('DesiredCapacity', 0)

        if len(instances_before) < desired:
            new_desired = desired + 2
            asg.set_desired_capacity(
                AutoScalingGroupName=ASG_NAME,
                DesiredCapacity=new_desired,
                HonorCooldown=False
            )
            action = 'scale_out'
            logger.info('Scaled out ASG to %d', new_desired)
        else:
            instance_ids = [i['InstanceId'] for i in instances_before]
            if instance_ids:
                cmd = 'sudo systemctl restart flask-app && sleep 5 && systemctl is-active flask-app'
                ssm.send_command(
                    InstanceIds=instance_ids,
                    DocumentName='AWS-RunShellScript',
                    Parameters={'commands': [cmd]}
                )
                action = 'service_restart'
                logger.info('Restarted flask-app on %d instances', len(instance_ids))
            else:
                logger.warning('No InService instances and desired=%d — no action taken', desired)

        _publish_metric(action, 'success')

    except Exception:
        logger.exception('Remediation failed')
        _publish_metric(action, 'failure')
        result = 'failure'

    log_entry = {
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'alarm_name': alarm_name,
        'action_taken': action,
        'result': result,
        'duration_ms': int((time.time() - start) * 1000)
    }
    _write_log('/techstream/remediation-events', f'remediation-{int(time.time())}', log_entry)

    subject = f'[TechStream AUTO-REMEDIATION] {action} — {datetime.utcnow().isoformat()}'
    body = f'Action: {action}\nResult: {result}\nAlarm: {alarm_name}\nDuration: {log_entry["duration_ms"]}ms'
    try:
        ses.send_email(
            Source=SES_FROM,
            Destination={'ToAddresses': [SES_TO]},
            Message={'Subject': {'Data': subject}, 'Body': {'Text': {'Data': body}}}
        )
    except Exception:
        logger.warning('SES notification failed', exc_info=True)

    return {'statusCode': 200, 'body': json.dumps({'action': action, 'result': result})}
