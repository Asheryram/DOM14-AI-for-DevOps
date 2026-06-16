import os
import json
import time
import boto3
from datetime import datetime

ASG_NAME = os.environ.get('ASG_NAME', 'TechStream-Prod-ASG')
SES_FROM = os.environ.get('SES_FROM', 'devops-guru@techstream.io')
SES_TO = os.environ.get('SES_TO', 'incidents@techstream.io')


def publish_metric(cloudwatch, action, result):
    cloudwatch.put_metric_data(
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


def handler(event, context):
    asg = boto3.client('autoscaling')
    ssm = boto3.client('ssm')
    cw = boto3.client('cloudwatch')
    logs = boto3.client('logs')
    ses = boto3.client('ses')

    alarm_name = event.get('detail', {}).get('alarmName', 'unknown')
    start = time.time()

    # Describe ASG
    ag = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[ASG_NAME])
    groups = ag.get('AutoScalingGroups', [])
    instances_before = []
    desired = 0
    if groups:
        group = groups[0]
        instances_before = [i for i in group.get('Instances', []) if i.get('LifecycleState') == 'InService']
        desired = group.get('DesiredCapacity', 0)

    action = 'none'
    try:
        if len(instances_before) < desired:
            # scale out
            new_desired = desired + 2
            asg.set_desired_capacity(AutoScalingGroupName=ASG_NAME, DesiredCapacity=new_desired, HonorCooldown=False)
            action = 'scale_out'
        else:
            # restart service via SSM
            instance_ids = [i['InstanceId'] for i in instances_before]
            if instance_ids:
                cmd = "sudo systemctl restart flask-app && sleep 5 && systemctl is-active flask-app"
                ssm.send_command(InstanceIds=instance_ids, DocumentName='AWS-RunShellScript', Parameters={'commands': [cmd]})
                action = 'service_restart'

        publish_metric(cw, action, 'success')
        result = 'success'
    except Exception as e:
        publish_metric(cw, action or 'none', 'failure')
        result = 'failure'

    # Log to CloudWatch Logs
    log_client = boto3.client('logs')
    group_name = '/techstream/remediation-events'
    try:
        log_client.create_log_group(logGroupName=group_name)
    except log_client.exceptions.ResourceAlreadyExistsException:
        pass
    stream = f"remediation-{int(time.time())}"
    try:
        log_client.create_log_stream(logGroupName=group_name, logStreamName=stream)
    except log_client.exceptions.ResourceAlreadyExistsException:
        pass
    log_entry = {
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'alarm_name': alarm_name,
        'instances_before': [i.get('InstanceId') for i in instances_before],
        'action_taken': action,
        'duration_ms': int((time.time() - start) * 1000)
    }
    log_client.put_log_events(logGroupName=group_name, logStreamName=stream, logEvents=[{'timestamp': int(time.time()*1000), 'message': json.dumps(log_entry)}])

    # Send SES email
    subject = f"[TechStream AUTO-REMEDIATION] {action} triggered — {datetime.utcnow().isoformat()}"
    body = f"Action taken: {action}\nInstances before: {len(instances_before)}\nAlarm: {alarm_name}"
    try:
        ses.send_email(Source=SES_FROM, Destination={'ToAddresses':[SES_TO]}, Message={'Subject':{'Data':subject}, 'Body':{'Text':{'Data':body}}})
    except Exception:
        pass

    return {'statusCode': 200, 'body': json.dumps({'action': action, 'result': result})}
