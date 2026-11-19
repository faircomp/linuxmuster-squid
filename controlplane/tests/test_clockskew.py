# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Kerberos clock skew per instance (ADR-017): validation, env, persistence, entrypoint."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml
from pydantic import ValidationError
from starlette.testclient import TestClient
from typer.testing import CliRunner

from lmnsquid import cli
from lmnsquid.docker_service import DockerService
from lmnsquid.models import Instance, InstancePatch
from lmnsquid.reconciler import Reconciler
from lmnsquid.store import Store
from lmnsquid.updater import Updater

ENTRYPOINT = Path(__file__).resolve().parents[2] / "image" / "entrypoint.sh"
NAME = "default-school-teachers"
# What env_for gave every instance before the setting existed (7.3.8): an instance at the
# default must get exactly this, or its spec fingerprint moves and an upgrade replaces it.
ENV_KEYS_738 = {
    "INSTANCE",
    "VISIBLE_HOSTNAME",
    "REALM",
    "AD_GROUP",
    "INTERNET_GROUP",
    "SCHOOL_SUBNETS",
    "KEYTAB",
    "CACHE_SIZE_MB",
    "HTTP_PORT",
    "LOG_RETENTION_DAYS",
    "ACCESS_LOG_ENABLED",
}


def _env(inst: Instance) -> dict[str, str]:
    return DockerService.env_for(DockerService.__new__(DockerService), inst)


# ------------------------------------------------------------------ model / validation
@pytest.mark.parametrize("bad", [299, 7201, 0, -300, "abc", "", 5400.5, None])
def test_rejects_out_of_range_and_non_numbers(instance_data: dict[str, Any], bad: Any) -> None:
    with pytest.raises(ValidationError):
        Instance(**instance_data, krb5_clockskew_seconds=bad)


@pytest.mark.parametrize("good", [300, 5400, 7200])
def test_accepts_the_range(instance_data: dict[str, Any], good: int) -> None:
    assert Instance(**instance_data, krb5_clockskew_seconds=good).krb5_clockskew_seconds == good


def test_default_is_mit_default_and_patchable(instance_data: dict[str, Any]) -> None:
    assert Instance(**instance_data).krb5_clockskew_seconds == 300
    assert InstancePatch(krb5_clockskew_seconds=5400).model_dump(exclude_unset=True) == {
        "krb5_clockskew_seconds": 5400
    }


# ------------------------------------------------------------------ env / container spec
def test_env_at_default_is_unchanged(instance_data: dict[str, Any]) -> None:
    for inst in (
        Instance(**instance_data),
        Instance(**instance_data, krb5_clockskew_seconds=300),
    ):
        assert set(_env(inst)) == ENV_KEYS_738


def test_env_carries_a_raised_value(instance_data: dict[str, Any]) -> None:
    env = _env(Instance(**instance_data, krb5_clockskew_seconds=5400))
    assert env["KRB5_CLOCKSKEW_SECONDS"] == "5400"
    assert set(env) == ENV_KEYS_738 | {"KRB5_CLOCKSKEW_SECONDS"}


# ------------------------------------------------------------------ API: set, keep, refuse
def test_patch_sets_persists_and_reaches_the_container(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
    store: Store,
    docker: Any,
) -> None:
    assert client.post("/v1/instances", json=instance_data, headers=auth_headers).status_code == 201
    assert "KRB5_CLOCKSKEW_SECONDS" not in docker.containers[NAME]["env"]

    r = client.patch(
        f"/v1/instances/{NAME}", json={"krb5_clockskew_seconds": 5400}, headers=auth_headers
    )
    assert r.status_code == 200, r.text
    assert r.json()["instance"]["krb5_clockskew_seconds"] == 5400
    assert docker.containers[NAME]["env"]["KRB5_CLOCKSKEW_SECONDS"] == "5400"
    # persisted in the instance definition (YAML), read back by a fresh store
    raw = yaml.safe_load((Path(store.path) / f"{NAME}.yaml").read_text(encoding="utf-8"))
    assert raw["krb5_clockskew_seconds"] == 5400
    assert Store(str(store.path)).get(NAME).krb5_clockskew_seconds == 5400  # type: ignore[union-attr]

    # back to the default: the env loses the variable again
    r = client.patch(
        f"/v1/instances/{NAME}", json={"krb5_clockskew_seconds": 300}, headers=auth_headers
    )
    assert r.status_code == 200, r.text
    assert "KRB5_CLOCKSKEW_SECONDS" not in docker.containers[NAME]["env"]


@pytest.mark.parametrize("bad", [299, 7201, "abc", None])
def test_patch_refuses_invalid_and_changes_nothing(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
    store: Store,
    docker: Any,
    bad: Any,
) -> None:
    client.post(
        "/v1/instances",
        json={**instance_data, "krb5_clockskew_seconds": 5400},
        headers=auth_headers,
    )
    calls = len(docker.ensure_calls)
    r = client.patch(
        f"/v1/instances/{NAME}", json={"krb5_clockskew_seconds": bad}, headers=auth_headers
    )
    assert r.status_code == 422  # a clear error, not a 500
    assert "krb5_clockskew_seconds" in r.text
    assert store.get(NAME).krb5_clockskew_seconds == 5400  # type: ignore[union-attr]
    assert len(docker.ensure_calls) == calls  # no container touched


def test_create_refuses_invalid(
    client: TestClient, auth_headers: dict[str, str], instance_data: dict[str, Any]
) -> None:
    r = client.post(
        "/v1/instances",
        json={**instance_data, "krb5_clockskew_seconds": 7201},
        headers=auth_headers,
    )
    assert r.status_code == 422
    assert "krb5_clockskew_seconds" in r.text


def test_kept_by_update_update_all_rollback_and_reconcile(
    store: Store,
    docker: Any,
    reconciler: Reconciler,
    updater: Updater,
    instance_data: dict[str, Any],
) -> None:
    reconciler.apply(Instance(**instance_data, krb5_clockskew_seconds=5400))

    def kept() -> None:
        assert store.get(NAME).krb5_clockskew_seconds == 5400  # type: ignore[union-attr]
        assert docker.containers[NAME]["env"]["KRB5_CLOCKSKEW_SECONDS"] == "5400"

    assert updater.update(NAME, "ghcr.io/example/lmnsquid:v2")["updated"] is True
    kept()
    assert updater.update(NAME, "ghcr.io/example/lmnsquid:bad")["updated"] is False  # rolled back
    kept()
    updater.rollback(NAME)
    kept()
    assert updater.update_all("ghcr.io/example/lmnsquid:v3")[0]["updated"] is True
    kept()
    docker.containers.clear()  # a fresh host: reconcile recreates from the store
    reconciler.reconcile_all()
    kept()


def test_definition_from_before_loads_with_the_default(
    store: Store, instance_data: dict[str, Any]
) -> None:
    # A YAML written by 7.3.8 has no such key.
    (Path(store.path) / f"{NAME}.yaml").write_text(yaml.safe_dump(instance_data), encoding="utf-8")
    assert store.get(NAME).krb5_clockskew_seconds == 300  # type: ignore[union-attr]


def test_hand_edited_definition_is_picked_up_by_reconcile_and_update(
    store: Store, docker: Any, reconciler: Reconciler, updater: Updater, instance: Instance
) -> None:
    reconciler.apply(instance)
    assert "KRB5_CLOCKSKEW_SECONDS" not in docker.containers[NAME]["env"]
    path = Path(store.path) / f"{NAME}.yaml"

    def hand_edit(value: object) -> None:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        data["krb5_clockskew_seconds"] = value
        path.write_text(yaml.safe_dump(data), encoding="utf-8")

    hand_edit(5400)
    reconciler.reconcile_all()
    assert docker.containers[NAME]["env"]["KRB5_CLOCKSKEW_SECONDS"] == "5400"

    hand_edit(7200)
    updater.update(NAME, "ghcr.io/example/lmnsquid:v2")
    assert docker.containers[NAME]["env"]["KRB5_CLOCKSKEW_SECONDS"] == "7200"


def test_invalid_hand_edit_leaves_the_running_container_alone(
    store: Store, docker: Any, reconciler: Reconciler, instance_data: dict[str, Any], caplog: Any
) -> None:
    reconciler.apply(Instance(**instance_data, krb5_clockskew_seconds=5400))
    path = Path(store.path) / f"{NAME}.yaml"
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    data["krb5_clockskew_seconds"] = 9000
    path.write_text(yaml.safe_dump(data), encoding="utf-8")
    calls = len(docker.ensure_calls)

    reconciler.reconcile_all()

    assert len(docker.ensure_calls) == calls  # skipped, not applied with a bad value
    assert docker.containers[NAME]["env"]["KRB5_CLOCKSKEW_SECONDS"] == "5400"
    assert f"invalid instance record in {NAME}.yaml" in caplog.text


# ------------------------------------------------------------------ CLI
def test_cli_create_and_edit(
    monkeypatch: pytest.MonkeyPatch, app: Any, token: str, instance_data: dict[str, Any]
) -> None:
    def factory() -> TestClient:
        tc = TestClient(app)
        tc.headers.update({"Authorization": f"Bearer {token}"})
        return tc

    monkeypatch.setattr(cli, "_get_client", factory)
    runner = CliRunner()
    args = ["create"]
    for key in ("school", "role", "ad_group", "realm", "visible_hostname", "keytab_secret"):
        args += [f"--{key.replace('_', '-')}", instance_data[key]]
    r = runner.invoke(cli.app, [*args, "--krb5-clockskew-seconds", "5400"])
    assert r.exit_code == 0, r.output
    assert '"krb5_clockskew_seconds": 5400' in runner.invoke(cli.app, ["show", NAME]).output

    r = runner.invoke(cli.app, ["edit", NAME, "--krb5-clockskew-seconds", "7200"])
    assert r.exit_code == 0, r.output
    assert '"krb5_clockskew_seconds": 7200' in runner.invoke(cli.app, ["show", NAME]).output

    r = runner.invoke(cli.app, ["edit", NAME, "--krb5-clockskew-seconds", "299"])
    assert r.exit_code == 1
    assert '"krb5_clockskew_seconds": 7200' in runner.invoke(cli.app, ["show", NAME]).output


# ------------------------------------------------------------------ entrypoint
def _entrypoint(tmp_path: Path, value: str) -> subprocess.CompletedProcess[str]:
    """Run image/entrypoint.sh until its first side effect.

    ``mkdir`` (the first command after the checks) is a stub that exits 97, so the script
    never touches the host: 97 = the value passed the check, 1 + FATAL = refused.
    """
    stubs = tmp_path / "stubs"
    stubs.mkdir(exist_ok=True)
    (stubs / "mkdir").write_text("#!/bin/sh\nexit 97\n", encoding="utf-8")
    (stubs / "mkdir").chmod(0o755)
    env = {
        "PATH": f"{stubs}:/usr/bin:/bin",
        "VISIBLE_HOSTNAME": "proxy.example.lan",
        "REALM": "EXAMPLE.LAN",
        "AD_GROUP": "teachers",
        "KRB5_CLOCKSKEW_SECONDS": value,
    }
    return subprocess.run(
        ["sh", str(ENTRYPOINT)], env=env, capture_output=True, text=True, timeout=30
    )


@pytest.mark.skipif(not shutil.which("sh"), reason="needs sh")
@pytest.mark.parametrize("bad", ["299", "7201", "abc", "0300", "-300", "300 ", "5400s", "99999"])
def test_entrypoint_refuses_invalid(tmp_path: Path, bad: str) -> None:
    done = _entrypoint(tmp_path, bad)
    assert done.returncode == 1, done.stderr
    assert "FATAL: KRB5_CLOCKSKEW_SECONDS=" in done.stderr


@pytest.mark.skipif(not shutil.which("sh"), reason="needs sh")
@pytest.mark.parametrize("good", ["300", "5400", "7200", ""])
def test_entrypoint_accepts_the_range(tmp_path: Path, good: str) -> None:
    done = _entrypoint(tmp_path, good)
    assert done.returncode == 97, done.stderr
    assert "FATAL" not in done.stderr


def test_entrypoint_writes_the_value_into_krb5_conf() -> None:
    # The heredoc that renders krb5.conf (the full render is asserted in the E2E).
    text = ENTRYPOINT.read_text(encoding="utf-8")
    block = text.split('cat > "${KRB5_CONFIG}" <<EOF', 1)[1].split("\nEOF\n", 1)[0]
    assert "[libdefaults]" in block
    assert "    clockskew = ${KRB5_CLOCKSKEW_SECONDS}" in block.splitlines()
