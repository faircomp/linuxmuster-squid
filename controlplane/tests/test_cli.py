# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""CLI (Typer) tests: drive the API via a TestClient-backed httpx client (fake docker)."""

from __future__ import annotations

from typing import Any

import pytest
from starlette.testclient import TestClient
from typer.testing import CliRunner

from lmnsquid import cli

runner = CliRunner()


@pytest.fixture
def patch_client(monkeypatch: pytest.MonkeyPatch, app: Any, token: str) -> None:
    """Make cli._get_client() return a fresh authenticated TestClient for `app`."""

    def factory() -> TestClient:
        tc = TestClient(app)
        tc.headers.update({"Authorization": f"Bearer {token}"})
        return tc

    monkeypatch.setattr(cli, "_get_client", factory)


def test_cli_full_lifecycle(patch_client: None, instance_data: dict[str, Any]) -> None:
    r = runner.invoke(
        cli.app,
        [
            "create",
            "--school", instance_data["school"],
            "--role", instance_data["role"],
            "--ad-group", instance_data["ad_group"],
            "--realm", instance_data["realm"],
            "--visible-hostname", instance_data["visible_hostname"],
            "--image", instance_data["image"],
            "--keytab-secret", instance_data["keytab_secret"],
        ],
    )
    assert r.exit_code == 0, r.output

    assert "default-school-teachers" in runner.invoke(cli.app, ["list"]).output
    assert runner.invoke(cli.app, ["status", "default-school-teachers"]).exit_code == 0
    assert runner.invoke(cli.app, ["stop", "default-school-teachers"]).exit_code == 0
    assert runner.invoke(cli.app, ["start", "default-school-teachers"]).exit_code == 0

    r = runner.invoke(
        cli.app,
        ["update", "default-school-teachers", "ghcr.io/example/lmnsquid:v2"],
    )
    assert r.exit_code == 0 and "\"updated\": true" in r.output

    assert runner.invoke(cli.app, ["rm", "default-school-teachers"]).exit_code == 0


def test_cli_show_missing_is_error(patch_client: None) -> None:
    r = runner.invoke(cli.app, ["show", "does-not-exist"])
    assert r.exit_code == 1


def test_cli_health_no_auth(monkeypatch: pytest.MonkeyPatch, app: Any) -> None:
    monkeypatch.setattr(cli, "_get_client", lambda: TestClient(app))
    r = runner.invoke(cli.app, ["health"])
    assert r.exit_code == 0
    assert "ok" in r.output
