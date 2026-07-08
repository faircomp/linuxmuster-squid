# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared pytest fixtures and an in-memory fake Docker backend.

The fake fully satisfies the :class:`lmnsquid.docker_service.DockerService`
interface so that :func:`lmnsquid.api.create_app` (and the reconciler) can be
exercised without a real Docker daemon.
"""

from __future__ import annotations

from typing import Any

import pytest
from starlette.testclient import TestClient

from lmnsquid.api import create_app
from lmnsquid.config import Settings
from lmnsquid.models import Instance
from lmnsquid.reconciler import Reconciler
from lmnsquid.store import Store
from lmnsquid.updater import Updater

TEST_TOKEN = "test-secret-token"


class FakeDockerService:
    """In-memory stand-in for :class:`lmnsquid.docker_service.DockerService`.

    Containers are tracked in a dict keyed by instance ``name`` (i.e. the
    ``<school>-<role>`` short name, not the ``lmnsquid-`` prefixed container
    name). Every method mirrors the real service's signature and return shape.
    """

    def __init__(
        self,
        docker_host: str | None = None,
        secrets_dir: str = "/etc/linuxmuster-squid/secrets",
    ) -> None:
        self.docker_host = docker_host
        self.secrets_dir = secrets_dir
        self.containers: dict[str, dict[str, Any]] = {}
        # Test-observability hooks.
        self.ensure_calls: list[str] = []
        self.removed: list[str] = []

    def env_for(self, inst: Instance) -> dict[str, str]:
        return {
            "INSTANCE": inst.name,
            "VISIBLE_HOSTNAME": inst.visible_hostname,
            "REALM": inst.realm,
            "AD_GROUP": inst.ad_group,
            "INTERNET_GROUP": inst.internet_group or "",
            "SCHOOL_SUBNETS": inst.school_subnets,
            "KEYTAB": f"/run/secrets/{inst.keytab_secret}",
            "CACHE_SIZE_MB": str(inst.cache_size_mb),
            "HTTP_PORT": str(inst.http_port),
            "LOG_RETENTION_DAYS": str(inst.log_retention_days),
            "ACCESS_LOG_ENABLED": "1" if inst.access_log_enabled else "0",
        }

    def ensure_running(self, inst: Instance) -> dict[str, Any]:
        self.ensure_calls.append(inst.name)
        if "unpullable" in inst.image:
            # Mirror the real service: the old container is force-removed before the new
            # one is created, so a pull/run failure leaves NO container and raises.
            self.containers.pop(inst.name, None)
            raise RuntimeError("simulated pull failure")
        self.containers[inst.name] = {
            "running": True,
            "image": inst.image,
            "health": "unhealthy" if "bad" in inst.image else "healthy",
            "env": self.env_for(inst),
            "logs": f"started {inst.container_name}\n",
            "access_logs": (
                "1783000000.0 0 10.0.0.1 TCP_MISS/200 - teacher1 GET http://ok.example/\n"
                "1783000001.0 0 10.0.0.2 TCP_DENIED/403 - student1 GET http://x.example/\n"
            ),
        }
        return self.status(inst.name)

    def start(self, name: str) -> dict[str, Any]:
        container = self.containers.get(name)
        if container is not None:
            container["running"] = True
        return self.status(name)

    def stop(self, name: str) -> dict[str, Any]:
        container = self.containers.get(name)
        if container is not None:
            container["running"] = False
        return self.status(name)

    def restart(self, name: str) -> dict[str, Any]:
        container = self.containers.get(name)
        if container is not None:
            container["running"] = True
        return self.status(name)

    def remove(self, name: str) -> None:
        self.removed.append(name)
        self.containers.pop(name, None)

    def status(self, name: str) -> dict[str, Any]:
        container = self.containers.get(name)
        if container is None:
            return {
                "name": name,
                "exists": False,
                "running": False,
                "health": None,
                "image": None,
            }
        return {
            "name": name,
            "exists": True,
            "running": bool(container["running"]),
            "health": container["health"],
            "image": container["image"],
        }

    def logs(
        self,
        name: str,
        tail: int = 100,
        since: int | None = None,
        until: int | None = None,
        grep: str | None = None,
    ) -> str:
        container = self.containers.get(name)
        if container is None:
            return ""
        lines = str(container["logs"]).splitlines()
        if grep:
            lines = [line for line in lines if grep in line]
        return "\n".join(lines[-tail:])

    def access_logs(
        self,
        name: str,
        since: int | None = None,
        until: int | None = None,
        grep: str | None = None,
        tail: int = 200,
    ) -> str:
        container = self.containers.get(name)
        if container is None:
            return ""
        lines = str(container.get("access_logs", "")).splitlines()
        if grep:
            lines = [line for line in lines if grep in line]
        return "\n".join(lines[-tail:])


@pytest.fixture
def token() -> str:
    return TEST_TOKEN


@pytest.fixture
def settings(tmp_path: Any, token: str) -> Settings:
    return Settings(
        api_token=token,
        instances_dir=str(tmp_path / "instances"),
        secrets_dir=str(tmp_path / "secrets"),
    )


@pytest.fixture
def store(settings: Settings) -> Store:
    return Store(settings.instances_dir)


@pytest.fixture
def docker(settings: Settings) -> FakeDockerService:
    return FakeDockerService(secrets_dir=settings.secrets_dir)


@pytest.fixture
def reconciler(store: Store, docker: FakeDockerService) -> Reconciler:
    return Reconciler(store, docker)  # type: ignore[arg-type]


@pytest.fixture
def updater(store: Store, docker: FakeDockerService, reconciler: Reconciler) -> Updater:
    return Updater(store, docker, reconciler, health_timeout=1.0, poll_interval=0.0)  # type: ignore[arg-type]


@pytest.fixture
def app(
    settings: Settings,
    store: Store,
    reconciler: Reconciler,
    docker: FakeDockerService,
    updater: Updater,
) -> Any:
    return create_app(settings, store, reconciler, docker, updater)  # type: ignore[arg-type]


@pytest.fixture
def client(app: Any) -> TestClient:
    return TestClient(app)


@pytest.fixture
def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def instance_data() -> dict[str, Any]:
    """A complete, valid Instance body for POST /v1/instances."""
    return {
        "school": "default-school",
        "role": "teachers",
        "ad_group": "teachers",
        "realm": "EXAMPLE.LAN",
        "visible_hostname": "proxy.example.lan",
        "http_port": 3128,
        "school_subnets": "10.0.0.0/16",
        "keytab_secret": "default-school-teachers.keytab",
        "cache_size_mb": 1000,
        "image": "ghcr.io/example/lmnsquid:latest",
    }


@pytest.fixture
def instance(instance_data: dict[str, Any]) -> Instance:
    return Instance(**instance_data)
