"""Shared pytest setup.

Sets a region + dummy credentials before any handler imports (the Lambda
handlers create boto3 clients at module load), disables the app's background
CloudWatch thread, and loads each module under test in isolation. The two Lambda
handlers are both named handler.py, so they are loaded via importlib under
distinct module names to avoid a sys.modules collision.
"""
import os
import sys
import importlib.util
from unittest.mock import MagicMock

import pytest

os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-1")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "testing")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "testing")
os.environ["ENABLE_CW_METRICS"] = "false"  # do not start the app's CW publisher thread

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "app"))


def _load(module_name, relpath):
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(ROOT, relpath))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def remediator():
    mod = _load("remediator_handler", "lambda/remediator/handler.py")
    mod.asg = MagicMock()
    mod.ssm = MagicMock()
    mod.cw = MagicMock()
    mod.logs = MagicMock()
    mod.ses = MagicMock()
    return mod


@pytest.fixture
def rca():
    mod = _load("rca_handler", "lambda/rca_summariser/handler.py")
    mod.bedrock = MagicMock()
    mod.ses = MagicMock()
    mod.cw = MagicMock()
    return mod


@pytest.fixture
def app_client():
    import app as app_module
    app_module.app.config.update(TESTING=True)
    return app_module.app.test_client()
