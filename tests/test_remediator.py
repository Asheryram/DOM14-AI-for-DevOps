import json


def _asg_response(instances_in_service, desired):
    return {
        "AutoScalingGroups": [{
            "DesiredCapacity": desired,
            "Instances": [
                {"InstanceId": f"i-{n}", "LifecycleState": "InService"}
                for n in range(instances_in_service)
            ],
        }]
    }


def test_parse_event_eventbridge(remediator):
    event = {"detail": {"alarmName": "TechStream-prod-CPU-High", "state": {"value": "ALARM"}}}
    assert remediator._parse_event(event) == ("TechStream-prod-CPU-High", "ALARM")


def test_parse_event_sns(remediator):
    event = {"Records": [{"Sns": {"Message": json.dumps(
        {"AlarmName": "TechStream-prod-ErrorRate-High", "NewStateValue": "ALARM"})}}]}
    assert remediator._parse_event(event) == ("TechStream-prod-ErrorRate-High", "ALARM")


def test_handler_ignores_non_alarm_state(remediator):
    event = {"detail": {"alarmName": "X", "state": {"value": "OK"}}}
    result = remediator.handler(event, None)
    body = json.loads(result["body"])
    assert body["action"] == "none"
    # Must not touch the ASG on a recovery/OK notification.
    remediator.asg.describe_auto_scaling_groups.assert_not_called()


def test_handler_scales_out_when_below_desired(remediator):
    remediator.asg.describe_auto_scaling_groups.return_value = _asg_response(1, 2)
    event = {"detail": {"alarmName": "TechStream-prod-CPU-High", "state": {"value": "ALARM"}}}
    result = remediator.handler(event, None)
    assert json.loads(result["body"])["action"] == "scale_out"
    remediator.asg.set_desired_capacity.assert_called_once()
    assert remediator.asg.set_desired_capacity.call_args.kwargs["DesiredCapacity"] == 4


def test_handler_restarts_service_when_at_capacity(remediator, monkeypatch):
    monkeypatch.setattr(remediator.time, "sleep", lambda *a, **k: None)
    remediator.asg.describe_auto_scaling_groups.return_value = _asg_response(2, 2)
    remediator.ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    remediator.ssm.get_command_invocation.return_value = {"Status": "Success"}
    event = {"detail": {"alarmName": "TechStream-prod-ErrorRate-High", "state": {"value": "ALARM"}}}
    result = remediator.handler(event, None)
    assert json.loads(result["body"])["action"] == "service_restart"
    # The restart must target the real systemd unit name.
    sent = remediator.ssm.send_command.call_args.kwargs["Parameters"]["commands"][0]
    assert "systemctl restart techstream" in sent
    assert "flask-app" not in sent


def test_restart_failure_is_reported(remediator, monkeypatch):
    monkeypatch.setattr(remediator.time, "sleep", lambda *a, **k: None)
    remediator.asg.describe_auto_scaling_groups.return_value = _asg_response(2, 2)
    remediator.ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    remediator.ssm.get_command_invocation.return_value = {
        "Status": "Failed", "StandardErrorContent": "unit not found"}
    event = {"detail": {"alarmName": "TechStream-prod-ErrorRate-High", "state": {"value": "ALARM"}}}
    result = remediator.handler(event, None)
    # A failed remote command must surface as failure, not silent success.
    assert json.loads(result["body"])["result"] == "failure"


def test_diagnostics_captured_before_restart(remediator, monkeypatch):
    # Memory-High → restart, and evidence must be snapshotted first.
    monkeypatch.setattr(remediator.time, "sleep", lambda *a, **k: None)
    remediator.asg.describe_auto_scaling_groups.return_value = _asg_response(2, 2)
    remediator.ssm.send_command.return_value = {"Command": {"CommandId": "cmd-1"}}
    remediator.ssm.get_command_invocation.return_value = {"Status": "Success", "StandardOutputContent": "== top =="}
    event = {"detail": {"alarmName": "TechStream-prod-Memory-High", "state": {"value": "ALARM"}}}
    result = remediator.handler(event, None)
    assert json.loads(result["body"])["action"] == "service_restart"
    sent_cmds = [c.kwargs["Parameters"]["commands"][0] for c in remediator.ssm.send_command.call_args_list]
    # A diagnostics snapshot (journalctl) must be taken, and the restart must run.
    assert any("journalctl" in c for c in sent_cmds)
    assert any("systemctl restart techstream" in c for c in sent_cmds)
