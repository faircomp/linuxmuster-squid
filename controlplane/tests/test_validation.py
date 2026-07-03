# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Security: reject path traversal / injection in instance fields and {name} path param."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import ValidationError

from lmnsquid.models import Instance, UpdateRequest


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
