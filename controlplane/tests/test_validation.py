# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Security: reject path traversal / injection in instance fields and {name} path param."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import ValidationError

from lmnsquid.models import DEFAULT_IMAGE, Instance, UpdateRequest


def _base(**over: Any) -> dict[str, Any]:
    data: dict[str, Any] = {
        "school": "s1",
        "role": "teachers",
        "ad_group": "teachers",
        "realm": "EXAMPLE.LAN",
        "visible_hostname": "proxy.example.lan",
        "keytab_secret": "proxy.keytab",
        "image": "ghcr.io/x/y:1.0",
        "school_subnets": "10.0.0.0/8",
    }
    data.update(over)
    return data


@pytest.mark.parametrize(
    ("field", "bad"),
    [
        ("school", "../../../etc/cron.d/x"),
        ("school", "a/b"),
        ("school", "a.b"),
        ("role", "a b"),
        ("keytab_secret", "../../../../etc/shadow"),
        ("keytab_secret", "sub/dir.keytab"),
        ("image", "ubuntu"),                       # bare repo -> pull-all-tags DoS
        ("image", "registry.local/proxy"),
        ("realm", "example.lan"),                  # must be uppercase
        ("visible_hostname", "bad host name"),
        ("school_subnets", "not-a-cidr"),
        ("http_port", 0),
        ("http_port", 70000),
        ("log_retention_days", 0),
        ("log_retention_days", 4000),
        ("internet_group", "bad/group"),          # path-ish -> invalid
    ],
)
def test_instance_rejects_bad_field(field: str, bad: Any) -> None:
    with pytest.raises(ValidationError):
        Instance(**_base(**{field: bad}))


def test_instance_accepts_good() -> None:
    Instance(**_base())
    Instance(**_base(image="ghcr.io/x/y@sha256:" + "a" * 64))


def test_update_request_requires_tag_or_digest() -> None:
    with pytest.raises(ValidationError):
        UpdateRequest(image="ubuntu")
    UpdateRequest(image="ghcr.io/x/y:2.0")


def test_instance_defaults_to_pinned_image() -> None:
    """Omitting image falls back to the maintained, digest-pinned default."""
    inst = Instance(**{k: v for k, v in _base().items() if k != "image"})
    assert inst.image == DEFAULT_IMAGE
    assert "@sha256:" in inst.image


def test_update_request_defaults_to_pinned_image() -> None:
    assert UpdateRequest().image == DEFAULT_IMAGE


def test_school_subnets_accepts_multiple_and_normalizes() -> None:
    assert Instance(**_base(school_subnets="10.1.0.0/16 10.2.0.0/16")).school_subnets == (
        "10.1.0.0/16 10.2.0.0/16"
    )
    # comma-separated / messy whitespace normalize to one space-separated string
    assert Instance(**_base(school_subnets="10.1.0.0/16,  10.2.0.0/16")).school_subnets == (
        "10.1.0.0/16 10.2.0.0/16"
    )
    # a single bad CIDR in the list still fails closed
    with pytest.raises(ValidationError):
        Instance(**_base(school_subnets="10.1.0.0/16 not-a-cidr"))


def test_internet_group_optional_and_validated() -> None:
    assert Instance(**_base()).internet_group is None                       # off by default
    assert Instance(**_base(internet_group="internet")).internet_group == "internet"
    assert Instance(**_base(internet_group="msg-internet")).internet_group == "msg-internet"
    with pytest.raises(ValidationError):
        Instance(**_base(internet_group="bad/group"))


def test_api_rejects_traversal_name(client: Any, auth_headers: dict[str, str]) -> None:
    for bad in ("..%2f..%2fetc%2fpasswd", "a%2fb", "UP", "..;bad"):
        resp = client.get(f"/v1/instances/{bad}", headers=auth_headers)
        assert resp.status_code in (404, 422), (bad, resp.status_code)


def test_patch_cannot_change_identity(
    client: Any, auth_headers: dict[str, str], instance_data: dict[str, Any]
) -> None:
    client.post("/v1/instances", json=instance_data, headers=auth_headers)
    # 'school' is not a patchable field -> ignored; the instance name stays the same.
    resp = client.patch(
        "/v1/instances/default-school-teachers",
        json={"school": "other", "cache_size_mb": 2000},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["instance"]["name"] == "default-school-teachers"


def test_dockerd_down_returns_503(
    client: Any,
    auth_headers: dict[str, str],
    docker: Any,
    instance_data: dict[str, Any],
    monkeypatch: Any,
) -> None:
    from docker.errors import DockerException

    client.post("/v1/instances", json=instance_data, headers=auth_headers)

    def boom(*_a: Any, **_k: Any) -> None:
        raise DockerException("daemon down")

    monkeypatch.setattr(docker, "status", boom)
    resp = client.get("/v1/instances/default-school-teachers/status", headers=auth_headers)
    assert resp.status_code == 503
    assert "docker daemon unreachable" in resp.json()["detail"]


def test_insecure_bind_warns(caplog: Any) -> None:
    import logging as _logging

    from lmnsquid.main import _warn_if_insecure_bind

    with caplog.at_level(_logging.WARNING, logger="lmnsquid"):
        _warn_if_insecure_bind("0.0.0.0")
    assert "cleartext" in caplog.text
    caplog.clear()
    with caplog.at_level(_logging.WARNING, logger="lmnsquid"):
        _warn_if_insecure_bind("127.0.0.1")
    assert "cleartext" not in caplog.text


def test_reconcile_endpoint(
    client: Any, auth_headers: dict[str, str], instance_data: dict[str, Any]
) -> None:
    client.post("/v1/instances", json=instance_data, headers=auth_headers)
    resp = client.post("/v1/reconcile", headers=auth_headers)
    assert resp.status_code == 200
    names = [s["name"] for s in resp.json()["reconciled"]]
    assert "default-school-teachers" in names
    assert client.post("/v1/reconcile").status_code == 401  # auth required


def test_log_query_endpoints(
    client: Any, auth_headers: dict[str, str], instance_data: dict[str, Any]
) -> None:
    client.post("/v1/instances", json=instance_data, headers=auth_headers)
    name = "default-school-teachers"

    live = client.get(f"/v1/instances/{name}/logs", params={"grep": "started"}, headers=auth_headers)
    assert live.status_code == 200 and "started" in live.json()["logs"]

    acc = client.get(
        f"/v1/instances/{name}/logs/access", params={"grep": "teacher1"}, headers=auth_headers
    )
    assert acc.status_code == 200
    assert "teacher1" in acc.json()["logs"] and "student1" not in acc.json()["logs"]

    for bad_tail in (0, 20000):
        r = client.get(
            f"/v1/instances/{name}/logs", params={"tail": bad_tail}, headers=auth_headers
        )
        assert r.status_code == 422, bad_tail
