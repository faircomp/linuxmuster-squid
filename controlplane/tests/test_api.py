# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""HTTP-level tests for the FastAPI control-plane API.

Uses the Starlette/httpx TestClient with the in-memory FakeDockerService, so
no real Docker daemon is required.
"""

from __future__ import annotations

from typing import Any

from starlette.testclient import TestClient


def test_health_needs_no_auth(client: TestClient) -> None:
    resp = client.get("/v1/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_version(client: TestClient, auth_headers: dict[str, str]) -> None:
    resp = client.get("/v1/version", headers=auth_headers)
    assert resp.status_code == 200
    assert "version" in resp.json()


def test_missing_token_is_401(client: TestClient) -> None:
    resp = client.get("/v1/instances")
    assert resp.status_code == 401


def test_wrong_token_is_403(client: TestClient) -> None:
    resp = client.get("/v1/instances", headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 403


def test_create_requires_auth(client: TestClient, instance_data: dict[str, Any]) -> None:
    resp = client.post("/v1/instances", json=instance_data)
    assert resp.status_code == 401


def test_happy_path_lifecycle(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
) -> None:
    name = "default-school-teachers"

    # create -> 201
    resp = client.post("/v1/instances", json=instance_data, headers=auth_headers)
    assert resp.status_code == 201
    body = resp.json()
    assert body["instance"]["name"] == name
    assert body["status"]["exists"] is True
    assert body["status"]["running"] is True

    # list
    resp = client.get("/v1/instances", headers=auth_headers)
    assert resp.status_code == 200
    listing = resp.json()
    assert isinstance(listing, list)
    assert any(i["name"] == name for i in listing)

    # get
    resp = client.get(f"/v1/instances/{name}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["name"] == name

    # status
    resp = client.get(f"/v1/instances/{name}/status", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["running"] is True

    # stop
    resp = client.post(f"/v1/instances/{name}/stop", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["running"] is False

    # start
    resp = client.post(f"/v1/instances/{name}/start", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["running"] is True

    # restart
    resp = client.post(f"/v1/instances/{name}/restart", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["running"] is True

    # logs
    resp = client.get(f"/v1/instances/{name}/logs", headers=auth_headers)
    assert resp.status_code == 200
    assert "logs" in resp.json()

    # delete -> 204
    resp = client.delete(f"/v1/instances/{name}", headers=auth_headers)
    assert resp.status_code == 204

    # gone
    resp = client.get(f"/v1/instances/{name}", headers=auth_headers)
    assert resp.status_code == 404


def test_get_unknown_is_404(client: TestClient, auth_headers: dict[str, str]) -> None:
    resp = client.get("/v1/instances/does-not-exist", headers=auth_headers)
    assert resp.status_code == 404


def test_patch_merges_onto_existing(
    client: TestClient,
    auth_headers: dict[str, str],
    instance_data: dict[str, Any],
) -> None:
    name = "default-school-teachers"
    created = client.post("/v1/instances", json=instance_data, headers=auth_headers)
    assert created.status_code == 201

    resp = client.patch(
        f"/v1/instances/{name}",
        json={"cache_size_mb": 4096},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["instance"]["cache_size_mb"] == 4096
    # untouched field preserved from the stored instance
    assert body["instance"]["realm"] == instance_data["realm"]

    stored = client.get(f"/v1/instances/{name}", headers=auth_headers).json()
    assert stored["cache_size_mb"] == 4096
