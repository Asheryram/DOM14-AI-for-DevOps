import os
import json
import time
import logging
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ASG_NAME = os.environ.get('ASG_NAME', 'TechStream-prod-ASG')
SES_FROM = os.environ.get('SES_FROM', 'devops-guru@techstream.io')
SES_TO   = os.environ.get('SES_TO',   'incidents@techstream.io')
# Name of the systemd unit the app runs under (see compute/user_data.sh.tpl).
APP_SERVICE = os.environ.get('APP_SERVICE', 'techstream')

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


def _parse_event(event):
    """Return (alarm_name, state) for both EventBridge and SNS event shapes."""
    # Primary path: EventBridge "CloudWatch Alarm State Change"
    if 'detail' in event:
        detail = event['detail']
        return detail.get('alarmName', 'unknown'), detail.get('state', {}).get('value', 'unknown')
    # Fallback path: SNS notification
    if event.get('Records'):
        try:
            msg = json.loads(event['Records'][0]['Sns']['Message'])
            return msg.get('AlarmName', 'unknown'), msg.get('NewStateValue', 'unknown')
        except (KeyError, json.JSONDecodeError):
            pass
    return 'unknown', 'unknown'


def _restart_app(instance_ids):
    """Restart the app via SSM and confirm the remote command actually succeeded."""
    cmd = (
        f'sudo systemctl restart {APP_SERVICE} && sleep 5 '
        f'&& systemctl is-active {APP_SERVICE}'
    )
    resp = ssm.send_command(
        InstanceIds=instance_ids,
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': [cmd]}
    )
    command_id = resp['Command']['CommandId']

    # Poll each instance for the terminal result instead of assuming success.
    failures = []
    for iid in instance_ids:
        for _ in range(20):  # up to ~40s
            time.sleep(2)
            try:
                inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=iid)
            except ssm.exceptions.InvocationDoesNotExist:
                continue
            if inv['Status'] in ('Success', 'Failed', 'Cancelled', 'TimedOut'):
                if inv['Status'] != 'Success':
                    failures.append(f"{iid}: {inv['Status']} {inv.get('StandardErrorContent', '')[:200]}")
                break
        else:
            failures.append(f"{iid}: timed out waiting for command result")

    if failures:
        raise RuntimeError('service restart failed on: ' + '; '.join(failures))
    logger.info('Restarted %s on %d instances', APP_SERVICE, len(instance_ids))


def handler(event, context):
    alarm_name, state = _parse_event(event)

    # Only remediate on an active ALARM. EventBridge already filters to ALARM,
    # but the SNS path also delivers OK/INSUFFICIENT_DATA transitions — acting on
    # those would scale out / restart during normal recovery.
    if state != 'ALARM':
        logger.info('Ignoring non-ALARM event (alarm=%s state=%s)', alarm_name, state)
        return {'statusCode': 200, 'body': json.dumps({'action': 'none', 'reason': f'state={state}'})}

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
                HonorCooldown=True
            )
            action = 'scale_out'
            logger.info('Scaled out ASG to %d', new_desired)
        else:
            instance_ids = [i['InstanceId'] for i in instances_before]
            if instance_ids:
                action = 'service_restart'
                _restart_app(instance_ids)
            else:
                logger.warning('No InService instances and desired=%d - no action taken', desired)

        _publish_metric(action, 'success')

    except Exception:
        logger.exception('Remediation failed')
        _publish_metric(action, 'failure')
        result = 'failure'

    log_entry = {
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'alarm_name': alarm_name,
        'action_taken': action,
        'result': result,
        'duration_ms': int((time.time() - start) * 1000)
    }
    _write_log('/techstream/remediation-events', f'remediation-{int(time.time())}', log_entry)

    subject = f'[TechStream AUTO-REMEDIATION] {action} ({result}) - {alarm_name}'
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
