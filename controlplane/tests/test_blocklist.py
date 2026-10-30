# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Blocklist product path: file helper, API endpoints, CLI, and what `rm` leaves behind."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from starlette.testclient import TestClient
from typer.testing import CliRunner

from lmnsquid import cli
from lmnsquid.blocklist import Blocklist, normalize_domain, uncovered
from lmnsquid.config import Settings

runner = CliRunner()


# ------------------------------------------------------------------ helper


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("example.com", ".example.com"),
        (".example.com", ".example.com"),
        ("  WWW.Example.COM.  ", ".www.example.com"),
        ("müller.de", ".xn--mller-kva.de"),
        ("intranet", ".intranet"),
    ],
)
def test_normalize_domain(raw: str, expected: str) -> None:
    assert normalize_domain(raw) == expected


@pytest.mark.parametrize(
    "bad", ["", ".", "bad host", "a/b", "-x.example.com", "ex_ample.com", "a" * 64 + ".com"]
)
def test_normalize_domain_rejects(bad: str) -> None:
    with pytest.raises(ValueError):
        normalize_domain(bad)


def test_blocklist_file_lifecycle(tmp_path: Path) -> None:
    bl = Blocklist(str(tmp_path / "blocklists"))
    directory = bl.ensure("s-teachers")
    file = directory / "blocked.domains"
    assert file.is_file() and file.read_text() == ""
    assert (file.stat().st_mode & 0o777) == 0o644
    assert (directory.stat().st_mode & 0o777) == 0o755

    assert bl.add("s-teachers", "Example.com") == [".example.com"]
    assert bl.add("s-teachers", "b.org") == [".b.org", ".example.com"]
    assert bl.add("s-teachers", ".example.com") == [".b.org", ".example.com"]  # idempotent
    assert file.read_text() == ".b.org\n.example.com\n"

    # a hand-edited file: comments/blank lines are ignored, a bare entry is removable too
    file.write_text("# managed\n\nexample.net\n.b.org\n")
    assert bl.read("s-teachers") == ["example.net", ".b.org"]
    assert bl.remove("s-teachers", "example.net") == [".b.org"]
    with pytest.raises(KeyError):
        bl.remove("s-teachers", "example.net")

    bl.delete("s-teachers")
    assert not directory.exists()
    assert bl.read("s-teachers") == []  # absent file reads as empty


@pytest.mark.parametrize(
    ("entries", "expected"),
    [
        # squid 6 refuses these orders ("FATAL: Bungled"): the covered name goes
        ([".graph.microsoft.com", ".microsoft.com"], [".microsoft.com"]),
        (["microsoft.com", ".microsoft.com"], [".microsoft.com"]),
        ([".microsoft.com", "a.b.microsoft.com", "MICROSOFT.COM."], [".microsoft.com"]),
        # duplicates (also by case and trailing dot) collapse
        ([".a.org", ".A.org", ".a.org."], [".a.org"]),
        # a bare name covers nothing, a sibling or a mere suffix is not covered
        (["a.org", "x.a.org"], ["a.org", "x.a.org"]),
        ([".a.org", ".ba.org", ".org.example"], [".a.org", ".ba.org", ".org.example"]),
        (["", " ", ".", ".b.org"], [".b.org"]),
    ],
)
def test_uncovered(entries: list[str], expected: list[str]) -> None:
    assert uncovered(entries) == expected


def test_add_never_writes_a_list_squid_cannot_load(tmp_path: Path) -> None:
    bl = Blocklist(str(tmp_path))
    file = tmp_path / "s-teachers" / "blocked.domains"
    assert bl.add("s-teachers", "graph.microsoft.com") == [".graph.microsoft.com"]
    # a parent replaces the names below it ...
    assert bl.add("s-teachers", "microsoft.com") == [".microsoft.com"]
    # ... and a name below a listed parent changes nothing
    assert bl.add("s-teachers", "login.microsoft.com") == [".microsoft.com"]
    assert file.read_text() == ".microsoft.com\n"
    # a hand-edited file with a covered name first is cleaned on the next write
    file.write_text(".a.example.org\n.example.org\nexample.org\n")
    assert bl.add("s-teachers", "other.org") == [".example.org", ".other.org"]
    file.write_text(".a.example.org\n.example.org\n.x.org\n")
    assert bl.remove("s-teachers", "x.org") == [".example.org"]


def test_blocklist_rejects_unsafe_name(tmp_path: Path) -> None:
    bl = Blocklist(str(tmp_path))
    for bad in ("../x", "a/b", "", ".", "a", "a.b"):
        with pytest.raises(ValueError):
            bl.ensure(bad)


# --------------------------------------------------------------------- API


def _create(client: TestClient, auth: dict[str, str], data: dict[str, Any]) -> str:
    assert client.post("/v1/instances", json=data, headers=auth).status_code == 201
    return "default-school-teachers"


def test_create_writes_empty_blocklist(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
    settings: Settings,
) -> None:
    name = _create(client, auth_headers, instance_data)
    file = Path(settings.blocklists_dir) / name / "blocked.domains"
    assert file.is_file() and file.read_text() == ""
    resp = client.get(f"/v1/instances/{name}/blocklist", headers=auth_headers)
    assert resp.status_code == 200 and resp.json() == {"name": name, "domains": []}


def test_blocklist_endpoints(
    client: TestClient, auth_headers: dict[str, str], instance_data: dict[str, Any], docker: Any
) -> None:
    name = _create(client, auth_headers, instance_data)

    resp = client.post(
        f"/v1/instances/{name}/blocklist", json={"domain": "Example.com"}, headers=auth_headers
    )
    assert resp.status_code == 200 and resp.json()["domains"] == [".example.com"]

    # invalid domain -> 422 at the boundary
    resp = client.post(
        f"/v1/instances/{name}/blocklist", json={"domain": "not a host"}, headers=auth_headers
    )
    assert resp.status_code == 422

    # reload -> squid -k reconfigure run in the running container
    resp = client.post(f"/v1/instances/{name}/blocklist/reload", headers=auth_headers)
    assert resp.status_code == 200 and resp.json() == {"name": name, "reloaded": True}
    assert docker.reloaded == [name]

    # stopped container -> 409, not a silent "ok"
    client.post(f"/v1/instances/{name}/stop", headers=auth_headers)
    assert (
        client.post(f"/v1/instances/{name}/blocklist/reload", headers=auth_headers).status_code
        == 409
    )

    resp = client.delete(f"/v1/instances/{name}/blocklist/example.com", headers=auth_headers)
    assert resp.status_code == 200 and resp.json()["domains"] == []
    assert (
        client.delete(
            f"/v1/instances/{name}/blocklist/example.com", headers=auth_headers
        ).status_code
        == 404
    )
    assert (
        client.delete(
            f"/v1/instances/{name}/blocklist/bad%20host", headers=auth_headers
        ).status_code
        == 422
    )


def test_blocklist_requires_auth_and_instance(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    assert client.get("/v1/instances/x-y/blocklist").status_code == 401
    assert client.get("/v1/instances/x-y/blocklist", headers=auth_headers).status_code == 404
    assert (
        client.post("/v1/instances/x-y/blocklist/reload", headers=auth_headers).status_code == 404
    )


def test_rm_removes_volumes_prev_and_blocklist(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
    docker: Any,
    settings: Settings,
) -> None:
    name = _create(client, auth_headers, instance_data)
    prev = Path(settings.instances_dir) / f"{name}.prev"
    prev.write_text(instance_data["image"])
    assert {f"lmnsquid-cache-{name}", f"lmnsquid-logs-{name}"} <= docker.volumes

    assert client.delete(f"/v1/instances/{name}", headers=auth_headers).status_code == 204

    assert not (Path(settings.blocklists_dir) / name).exists()
    assert not prev.exists()
    assert not (Path(settings.instances_dir) / f"{name}.yaml").exists()
    assert docker.volumes == set()


def test_rm_keep_logs_retains_log_volume(
    client: TestClient, auth_headers: dict[str, str], instance_data: dict[str, Any], docker: Any
) -> None:
    name = _create(client, auth_headers, instance_data)
    assert (
        client.delete(
            f"/v1/instances/{name}", params={"keep_logs": "true"}, headers=auth_headers
        ).status_code
        == 204
    )
    assert docker.volumes == {f"lmnsquid-logs-{name}"}


# --------------------------------------------------------------------- CLI


@pytest.fixture
def patch_client(monkeypatch: pytest.MonkeyPatch, app: Any, token: str) -> None:
    def factory() -> TestClient:
        tc = TestClient(app)
        tc.headers.update({"Authorization": f"Bearer {token}"})
        return tc

    monkeypatch.setattr(cli, "_get_client", factory)


def test_cli_blocklist_and_rm(
    patch_client: None, instance_data: dict[str, Any], docker: Any
) -> None:
    r = runner.invoke(
        cli.app,
        [
            "create",
            "--school",
            instance_data["school"],
            "--role",
            instance_data["role"],
            "--ad-group",
            instance_data["ad_group"],
            "--realm",
            instance_data["realm"],
            "--visible-hostname",
            instance_data["visible_hostname"],
            "--keytab-secret",
            instance_data["keytab_secret"],
        ],
    )
    assert r.exit_code == 0, r.output
    name = "default-school-teachers"

    r = runner.invoke(cli.app, ["blocklist", name, "add", "example.com"])
    assert r.exit_code == 0 and '".example.com"' in r.output, r.output
    r = runner.invoke(cli.app, ["blocklist", name, "list"])
    assert r.exit_code == 0 and '".example.com"' in r.output
    r = runner.invoke(cli.app, ["blocklist", name, "reload"])
    assert r.exit_code == 0 and '"reloaded": true' in r.output
    assert docker.reloaded == [name]
    r = runner.invoke(cli.app, ["blocklist", name, "remove", "example.com"])
    assert r.exit_code == 0 and '".example.com"' not in r.output
    assert runner.invoke(cli.app, ["blocklist", name, "remove", "example.com"]).exit_code == 1
    assert runner.invoke(cli.app, ["blocklist", name, "add", "bad host"]).exit_code == 1

    assert runner.invoke(cli.app, ["rm", name, "--keep-logs"]).exit_code == 0
    assert docker.volumes == {f"lmnsquid-logs-{name}"}
