# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""DockerService.ensure_running against a mocked docker-py client: spec fingerprint,
no-op for a matching container, and the create-first replacement with rollback."""

from __future__ import annotations

from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest
from docker.errors import APIError, NotFound

from lmnsquid.blocklist import Blocklist, noauth_list
from lmnsquid.docker_service import SPEC_LABEL, DockerService
from lmnsquid.models import Instance


def _service(tmp_path: Path) -> DockerService:
    ds = DockerService.__new__(DockerService)  # bypass __init__ (no docker daemon)
    ds.client = MagicMock()
    ds.secrets_dir = str(tmp_path / "secrets")
    ds.blocklist = Blocklist(str(tmp_path / "blocklists"))
    ds.noauth = noauth_list(str(tmp_path / "blocklists"))
    ds.container_bind_ip = "0.0.0.0"
    ds.log_max_size = "20m"
    ds.log_max_file = 5
    ds.health_timeout = 1.0
    ds.poll_interval = 0.0
    return ds


def _inst(**over: Any) -> Instance:
    data: dict[str, Any] = dict(
        school="s",
        role="teachers",
        ad_group="teachers",
        realm="EX.LAN",
        visible_hostname="proxy.example.lan",
        keytab_secret="proxy.keytab",
        image="ghcr.io/x/y:1",
    )
    data.update(over)
    return Instance(**data)


def _container(name: str, labels: dict[str, str] | None = None, running: bool = True) -> MagicMock:
    c = MagicMock(name=name)
    c.labels = labels or {}
    c.attrs = {"State": {"Running": running, "Health": {"Status": "healthy"}}, "Config": {}}
    c.image.tags = ["ghcr.io/x/y:1"]
    return c


def _registry(ds: DockerService, containers: dict[str, MagicMock]) -> None:
    def get(name: str) -> MagicMock:
        if name in containers:
            return containers[name]
        raise NotFound(f"no such container {name}")

    ds.client.containers.get.side_effect = get


def test_fingerprint_is_stable_and_sensitive(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    base = ds.fingerprint(ds.spec_for(_inst()))
    assert base == ds.fingerprint(ds.spec_for(_inst()))
    assert base != ds.fingerprint(ds.spec_for(_inst(image="ghcr.io/x/y:2")))
    assert base != ds.fingerprint(ds.spec_for(_inst(http_port=3129)))
    assert base != ds.fingerprint(ds.spec_for(_inst(keytab_secret="other.keytab")))
    spec = ds.spec_for(_inst())
    blocklist_dir = str(tmp_path / "blocklists" / "s-teachers")
    assert spec["volumes"][blocklist_dir]["bind"] == "/etc/squid/lists"
    # The noauth list lives in the same mounted directory: no mount of its own, so the
    # spec (and with it every container an upgrade would otherwise replace) is unchanged.
    assert len(spec["volumes"]) == 4
    assert not any("noauth" in str(k) or "noauth" in str(v) for k, v in spec.items())


def test_ensure_running_creates_both_lists_before_the_container(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    _registry(ds, {})
    seen: list[bool] = []
    lists = tmp_path / "blocklists" / "s-teachers"

    def create(*_a: Any, **_k: Any) -> MagicMock:
        # The entrypoint reads noauth.domains only when it is there at container start.
        seen.append((lists / "noauth.domains").is_file() and (lists / "blocked.domains").is_file())
        return _container("lmnsquid-s-teachers.new")

    ds.client.containers.create.side_effect = create
    ds.ensure_running(_inst())
    assert seen == [True]
    assert (lists / "noauth.domains").read_text() == ""


@pytest.mark.parametrize(("grep_exit", "expected"), [(0, True), (1, False)])
def test_noauth_active_reads_the_rendered_config(
    tmp_path: Path, grep_exit: int, expected: bool
) -> None:
    ds = _service(tmp_path)
    c = _container("lmnsquid-s-teachers")
    c.exec_run.return_value = (grep_exit, b"")
    _registry(ds, {"lmnsquid-s-teachers": c})
    assert ds.noauth_active("s-teachers") is expected
    cmd = c.exec_run.call_args.args[0]
    assert cmd == ["grep", "-qF", "acl noauth_domains ", "/run/lmnsquid/squid.conf"]


def test_reload_syncs_the_lists_then_reconfigures(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    c = _container("lmnsquid-s-teachers")
    c.exec_run.return_value = (0, b"")
    _registry(ds, {"lmnsquid-s-teachers": c})
    c.exec_run.return_value = (
        0,
        b"linuxmuster-squid: noauth.domains: ignored, not a domain name: com\n"
        b"squid: some other line\n",
    )
    assert ds.reload("s-teachers") == {
        "name": "s-teachers",
        "reloaded": True,
        "notices": ["noauth.domains: ignored, not a domain name: com"],
    }
    cmd = c.exec_run.call_args.args[0]
    assert cmd[:2] == ["sh", "-c"]
    # lists-sync.sh first (only where the image has it), then squid -k reconfigure.
    assert "[ -x /usr/local/bin/lists-sync.sh ]" in cmd[2]
    assert cmd[2].index("lists-sync.sh 2>") < cmd[2].index("squid -k reconfigure")
    assert ">> /run/lmnsquid/lists-sync.log" in cmd[2]
    assert cmd[2].endswith("exec squid -k reconfigure -f /run/lmnsquid/squid.conf")

    c.exec_run.return_value = (1, b"FATAL: Bungled /run/lmnsquid/squid.conf line 59")
    with pytest.raises(RuntimeError, match="Bungled"):
        ds.reload("s-teachers")


def test_noauth_active_errors(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    stopped = _container("lmnsquid-s-teachers", running=False)
    _registry(ds, {"lmnsquid-s-teachers": stopped})
    with pytest.raises(LookupError):
        ds.noauth_active("s-teachers")
    _registry(ds, {})
    with pytest.raises(LookupError):
        ds.noauth_active("s-teachers")
    broken = _container("lmnsquid-s-teachers")
    broken.exec_run.return_value = (2, b"grep: /run/lmnsquid/squid.conf: No such file")
    _registry(ds, {"lmnsquid-s-teachers": broken})
    with pytest.raises(RuntimeError, match="cannot read"):
        ds.noauth_active("s-teachers")
    refused = _container("lmnsquid-s-teachers")
    refused.exec_run.side_effect = APIError("exec disabled")
    _registry(ds, {"lmnsquid-s-teachers": refused})
    with pytest.raises(RuntimeError, match="EXEC"):
        ds.noauth_active("s-teachers")


def test_spec_rejects_a_keytab_outside_secrets_dir(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    inst = _inst()
    # The model forbids '/' and '..' in keytab_secret; the service checks again right
    # before the value becomes a bind mount (defense in depth), so bypass the model.
    object.__setattr__(inst, "keytab_secret", "../../etc/shadow")
    with pytest.raises(ValueError, match="escapes secrets_dir"):
        ds.spec_for(inst)


def test_matching_container_is_left_alone(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    inst = _inst()
    digest = ds.fingerprint(ds.spec_for(inst))
    existing = _container("lmnsquid-s-teachers", {SPEC_LABEL: digest}, running=False)
    _registry(ds, {"lmnsquid-s-teachers": existing})

    ds.ensure_running(inst)

    ds.client.containers.create.assert_not_called()
    existing.start.assert_called_once()  # stopped but matching -> just started
    existing.remove.assert_not_called()


def test_replacement_creates_new_first_and_removes_old_only_when_healthy(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    inst = _inst()
    existing = _container("lmnsquid-s-teachers", {SPEC_LABEL: "stale"})
    _registry(ds, {"lmnsquid-s-teachers": existing})
    new = _container("new")
    ds.client.containers.create.return_value = new
    ds._wait_healthy = lambda c: None  # type: ignore[method-assign]

    ds.ensure_running(inst)

    kwargs = ds.client.containers.create.call_args.kwargs
    assert kwargs["name"] == "lmnsquid-s-teachers.new"
    assert kwargs["labels"] == {SPEC_LABEL: ds.fingerprint(ds.spec_for(inst))}
    existing.stop.assert_called_once()
    existing.rename.assert_called_once_with("lmnsquid-s-teachers.old")
    new.rename.assert_called_once_with("lmnsquid-s-teachers")
    new.start.assert_called_once()
    existing.remove.assert_called_once_with(force=True)
    new.remove.assert_not_called()


def test_unhealthy_replacement_restores_the_old_container(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    inst = _inst()
    existing = _container("lmnsquid-s-teachers", {SPEC_LABEL: "stale"})
    _registry(ds, {"lmnsquid-s-teachers": existing})
    new = _container("new")
    ds.client.containers.create.return_value = new
    ds._wait_healthy = lambda c: "exited with code 1"  # type: ignore[method-assign]

    with pytest.raises(RuntimeError, match="exited with code 1.*previous container restored"):
        ds.ensure_running(inst)

    new.remove.assert_called_once_with(force=True)
    existing.remove.assert_not_called()
    assert existing.rename.call_args_list[-1].args == ("lmnsquid-s-teachers",)
    existing.start.assert_called_once()


def test_create_failure_leaves_old_container_untouched(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    existing = _container("lmnsquid-s-teachers", {SPEC_LABEL: "stale"})
    _registry(ds, {"lmnsquid-s-teachers": existing})
    ds.client.containers.create.side_effect = NotFound("image gone")

    with pytest.raises(NotFound):
        ds.ensure_running(_inst())

    existing.stop.assert_not_called()
    existing.rename.assert_not_called()
    existing.remove.assert_not_called()


def test_a_failed_swap_does_not_leave_a_spare_container(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    existing = _container("lmnsquid-s-teachers", {SPEC_LABEL: "stale"})
    existing.stop.side_effect = APIError("daemon busy")
    _registry(ds, {"lmnsquid-s-teachers": existing})
    new = _container("new")
    ds.client.containers.create.return_value = new

    with pytest.raises(APIError):
        ds.ensure_running(_inst())

    new.remove.assert_called_once_with(force=True)  # the spare is dropped
    existing.rename.assert_not_called()
    existing.remove.assert_not_called()


def test_wait_healthy_fails_fast_on_exit(tmp_path: Path) -> None:
    ds = _service(tmp_path)
    c = MagicMock()
    c.attrs = {
        "Config": {"Healthcheck": {"Test": ["CMD", "x"]}},
        "State": {"Running": False, "ExitCode": 2},
    }
    assert ds._wait_healthy(c) == "exited with code 2"
    c.attrs = {"Config": {}, "State": {"Running": True}}
    assert ds._wait_healthy(c) is None  # no HEALTHCHECK in the image -> running is enough
    c.attrs = {
        "Config": {"Healthcheck": {"Test": ["CMD", "x"]}},
        "State": {"Running": True, "Health": {"Status": "starting"}},
    }
    assert "not healthy after" in (ds._wait_healthy(c) or "")
