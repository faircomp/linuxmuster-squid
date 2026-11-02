# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Domains without proxy auth (ADR-016): list file, API endpoints, CLI, and `rm`."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
from starlette.testclient import TestClient
from typer.testing import CliRunner

from lmnsquid import cli
from lmnsquid.blocklist import Blocklist, noauth_list, normalize_noauth_domain
from lmnsquid.config import Settings

runner = CliRunner()
NAME = "default-school-teachers"


def _create(client: TestClient, auth: dict[str, str], data: dict[str, Any]) -> str:
    assert client.post("/v1/instances", json=data, headers=auth).status_code == 201
    return NAME


# ------------------------------------------------------------------ helper


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("office.com", [".office.com"]),
        ("  Outlook.Office.COM. ", [".outlook.office.com"]),
        (".sharepoint.com", [".sharepoint.com"]),
        ("bücher.de", [".xn--bcher-kva.de"]),
    ],
)
def test_noauth_add_normalizes(tmp_path: Path, raw: str, expected: list[str]) -> None:
    na = noauth_list(str(tmp_path))
    assert na.add("s-teachers", raw) == expected
    assert (tmp_path / "s-teachers" / "noauth.domains").read_text() == f"{expected[0]}\n"


@pytest.mark.parametrize(
    "bad",
    [
        "",
        ".",
        "*.office.com",
        "office.com/x",
        "a b.com",
        "-x.com",
        "x_y.com",
        "a" * 64,
        # IP literals in every form squid would see as a host, and single labels (a TLD)
        "172.28.0.20",
        "10.0.0.1",
        "127.1",
        "0x7f000001",
        "0x7f.0x1",
        "1.2.3.0x4",
        "0x0a.0x00.0x00.0x01",
        "0177.0.0.1",
        "2887516181",
        "::1",
        "[::1]",
        "::ffff:172.28.0.21",
        "com",
        ".com",
        "intranet",
    ],
)
def test_noauth_add_rejects_invalid_names(tmp_path: Path, bad: str) -> None:
    na = noauth_list(str(tmp_path))
    with pytest.raises(ValueError):
        na.add("s-teachers", bad)
    assert not (tmp_path / "s-teachers" / "noauth.domains").exists()


@pytest.mark.parametrize("bad", ["../x", "a/b", "..", "", "a", "a.b", "/etc"])
def test_noauth_rejects_unsafe_instance_name(tmp_path: Path, bad: str) -> None:
    na = noauth_list(str(tmp_path / "lists"))
    with pytest.raises(ValueError):
        na.add(bad, "office.com")
    assert not (tmp_path / "x").exists() and not (tmp_path / "lists").exists()


def test_both_lists_share_the_directory(tmp_path: Path) -> None:
    root = str(tmp_path)
    bl, na = Blocklist(root), noauth_list(root)
    bl.add("s-teachers", "blocked.example")
    na.add("s-teachers", "office.com")
    directory = tmp_path / "s-teachers"
    assert sorted(p.name for p in directory.iterdir()) == ["blocked.domains", "noauth.domains"]
    assert bl.read("s-teachers") == [".blocked.example"]
    assert na.read("s-teachers") == [".office.com"]
    assert (directory / "noauth.domains").stat().st_mode & 0o777 == 0o644
    na.remove("s-teachers", "office.com")
    assert bl.read("s-teachers") == [".blocked.example"]  # the other list is untouched
    na.delete("s-teachers")  # rm: the directory goes with both lists
    assert not directory.exists()


def test_noauth_read_and_add_with_crlf(tmp_path: Path) -> None:
    file = tmp_path / "s-teachers" / "noauth.domains"
    file.parent.mkdir()
    file.write_bytes(b".office.com\r\n.sharepoint.com\r\n")
    na = noauth_list(str(tmp_path))
    assert na.read("s-teachers") == [".office.com", ".sharepoint.com"]
    assert na.add("s-teachers", "teams.microsoft.com") == [
        ".office.com",
        ".sharepoint.com",
        ".teams.microsoft.com",
    ]
    assert b"\r" not in file.read_bytes()


def test_noauth_names_vs_blocklist_names(tmp_path: Path) -> None:
    # a domain below a TLD with letters in the last label passes, also IDNA and digits inside
    assert normalize_noauth_domain("1und1.de") == ".1und1.de"
    assert normalize_noauth_domain("x.co.uk") == ".x.co.uk"
    # the blocklist keeps accepting a TLD and an address on purpose: a wrong entry there
    # only blocks more
    bl = Blocklist(str(tmp_path))
    assert bl.add("s-teachers", "zip") == [".zip"]
    assert bl.add("s-teachers", "10.0.0.1") == [".10.0.0.1", ".zip"]


def test_noauth_remove_accepts_what_add_refuses(tmp_path: Path) -> None:
    # a hand-written "com" or address can still be taken out with the CLI
    file = tmp_path / "s-teachers" / "noauth.domains"
    file.parent.mkdir()
    file.write_text(".com\n10.0.0.1\n.office.com\n")
    na = noauth_list(str(tmp_path))
    assert na.remove("s-teachers", "com") == [".office.com", "10.0.0.1"]
    assert na.remove("s-teachers", "10.0.0.1") == [".office.com"]


# --------------------------------------------------------------------- API


def test_noauth_requires_token(client: TestClient) -> None:
    assert client.get(f"/v1/instances/{NAME}/noauth").status_code == 401
    assert client.post(f"/v1/instances/{NAME}/noauth", json={"domain": "x.org"}).status_code == 401
    assert client.delete(f"/v1/instances/{NAME}/noauth/x.org").status_code == 401
    assert client.post(f"/v1/instances/{NAME}/noauth/reload").status_code == 401
    bad = {"Authorization": "Bearer nope"}
    assert client.get(f"/v1/instances/{NAME}/noauth", headers=bad).status_code == 403


def test_noauth_unknown_or_unsafe_instance(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    assert client.get("/v1/instances/x-y/noauth", headers=auth_headers).status_code == 404
    resp = client.post("/v1/instances/x-y/noauth", json={"domain": "x.org"}, headers=auth_headers)
    assert resp.status_code == 404
    assert client.post("/v1/instances/x-y/noauth/reload", headers=auth_headers).status_code == 404
    # a traversal attempt never reaches the file system
    resp = client.get("/v1/instances/..%2F..%2Fetc/noauth", headers=auth_headers)
    assert resp.status_code in (404, 422)


def test_noauth_endpoints(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
    docker: Any,
    settings: Settings,
) -> None:
    name = _create(client, auth_headers, instance_data)
    file = Path(settings.blocklists_dir) / name / "noauth.domains"
    assert file.is_file() and file.read_text() == ""  # created empty with the instance
    resp = client.get(f"/v1/instances/{name}/noauth", headers=auth_headers)
    assert resp.status_code == 200 and resp.json() == {"name": name, "domains": []}

    resp = client.post(
        f"/v1/instances/{name}/noauth", json={"domain": "Office.com"}, headers=auth_headers
    )
    assert resp.status_code == 200 and resp.json()["domains"] == [".office.com"]
    assert file.read_text() == ".office.com\n"
    # the blocklist is a separate file in the same directory
    assert client.get(f"/v1/instances/{name}/blocklist", headers=auth_headers).json() == {
        "name": name,
        "domains": [],
    }

    for bad in ("not a host", "172.28.0.20", "com", "127.1", "::1"):
        resp = client.post(
            f"/v1/instances/{name}/noauth", json={"domain": bad}, headers=auth_headers
        )
        assert resp.status_code == 422, bad
    assert file.read_text() == ".office.com\n"

    resp = client.post(f"/v1/instances/{name}/noauth/reload", headers=auth_headers)
    assert resp.status_code == 200 and resp.json() == {
        "name": name,
        "reloaded": True,
        "notices": [],
    }
    assert docker.reloaded == [name]

    resp = client.delete(f"/v1/instances/{name}/noauth/office.com", headers=auth_headers)
    assert resp.status_code == 200 and resp.json()["domains"] == []
    resp = client.delete(f"/v1/instances/{name}/noauth/office.com", headers=auth_headers)
    assert resp.status_code == 404
    resp = client.delete(f"/v1/instances/{name}/noauth/bad%20host", headers=auth_headers)
    assert resp.status_code == 422

    client.post(f"/v1/instances/{name}/stop", headers=auth_headers)
    resp = client.post(f"/v1/instances/{name}/noauth/reload", headers=auth_headers)
    assert resp.status_code == 409


def test_noauth_reload_refuses_an_image_that_ignores_the_list(
    client: TestClient, auth_headers: dict[str, str], instance_data: dict[str, Any], docker: Any
) -> None:
    data = {**instance_data, "image": "ghcr.io/faircomp/linuxmuster-squid:old"}
    name = _create(client, auth_headers, data)
    client.post(f"/v1/instances/{name}/noauth", json={"domain": "office.com"}, headers=auth_headers)
    resp = client.post(f"/v1/instances/{name}/noauth/reload", headers=auth_headers)
    assert resp.status_code == 409
    detail = resp.json()["detail"]
    assert "does not support the noauth list" in detail and "release" in detail
    # `lmnsquid update` only after the release (before it, it pulls the same old image)
    assert "installing that release" in detail and f"lmnsquid update {name}" in detail
    assert docker.reloaded == []  # no "reloaded" that changes nothing
    # the blocklist reload is unaffected
    resp = client.post(f"/v1/instances/{name}/blocklist/reload", headers=auth_headers)
    assert resp.status_code == 200


def test_rm_removes_the_noauth_list(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
    settings: Settings,
) -> None:
    name = _create(client, auth_headers, instance_data)
    client.post(f"/v1/instances/{name}/noauth", json={"domain": "office.com"}, headers=auth_headers)
    assert client.delete(f"/v1/instances/{name}", headers=auth_headers).status_code == 204
    assert not (Path(settings.blocklists_dir) / name).exists()


# --------------------------------------------------------------------- CLI


@pytest.fixture
def patch_client(monkeypatch: pytest.MonkeyPatch, app: Any, token: str) -> None:
    def factory() -> TestClient:
        tc = TestClient(app)
        tc.headers.update({"Authorization": f"Bearer {token}"})
        return tc

    monkeypatch.setattr(cli, "_get_client", factory)


def test_cli_noauth(patch_client: None, instance_data: dict[str, Any], docker: Any) -> None:
    args = ["create", "--school", instance_data["school"], "--role", instance_data["role"]]
    for key in ("ad_group", "realm", "visible_hostname", "keytab_secret"):
        args += [f"--{key.replace('_', '-')}", instance_data[key]]
    assert runner.invoke(cli.app, args).exit_code == 0

    r = runner.invoke(cli.app, ["noauth", NAME, "add", "office.com"])
    assert r.exit_code == 0 and '".office.com"' in r.output, r.output
    r = runner.invoke(cli.app, ["noauth", NAME, "list"])
    assert r.exit_code == 0 and '".office.com"' in r.output
    r = runner.invoke(cli.app, ["noauth", NAME, "reload"])
    assert r.exit_code == 0 and '"reloaded": true' in r.output
    r = runner.invoke(cli.app, ["noauth", NAME, "remove", "office.com"])
    assert r.exit_code == 0 and '".office.com"' not in r.output
    assert runner.invoke(cli.app, ["noauth", NAME, "remove", "office.com"]).exit_code == 1
    assert runner.invoke(cli.app, ["noauth", NAME, "add", "bad host"]).exit_code == 1
    assert runner.invoke(cli.app, ["noauth", NAME, "add", "10.0.0.1"]).exit_code == 1
    assert runner.invoke(cli.app, ["noauth", NAME, "add", "com"]).exit_code == 1


def test_cli_noauth_help_warns() -> None:
    r = runner.invoke(cli.app, ["noauth", "--help"])
    assert r.exit_code == 0
    text = " ".join(r.output.split())
    for needle in ("exam mode", "Internetsperre", "school-subnets", "blocklist still wins"):
        assert needle in text, needle
