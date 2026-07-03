# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Docker orchestration for linuxmuster-squid instances via the docker-py SDK."""

from __future__ import annotations

import os
from typing import Any, Optional

import docker
from docker.errors import ImageNotFound, NotFound
from docker.models.containers import Container
from docker.types import LogConfig

from .models import Instance


class DockerService:
    """Manage one Squid container per instance through the Docker Engine API.

    A container's real name is derived as ``lmnsquid-<name>`` where ``<name>``
    is the instance's :pyattr:`Instance.name` (``<school>-<role>``).
    """

    def __init__(
        self,
        docker_host: Optional[str] = None,
        secrets_dir: str = "/etc/linuxmuster-squid/secrets",
        container_bind_ip: str = "127.0.0.1",
        log_max_size: str = "20m",
        log_max_file: int = 5,
    ) -> None:
        self.docker_host: Optional[str] = docker_host
        self.secrets_dir: str = secrets_dir
        self.container_bind_ip: str = container_bind_ip
        self.log_max_size: str = log_max_size
        self.log_max_file: int = log_max_file
        self.client: docker.DockerClient = (
            docker.DockerClient(base_url=docker_host) if docker_host else docker.from_env()
        )

    # -- helpers -----------------------------------------------------------

    @staticmethod
    def _container_name(name: str) -> str:
        return f"lmnsquid-{name}"

    def _get(self, name: str) -> Optional[Container]:
        """Return the container for ``name`` or ``None`` if it does not exist."""
        try:
            return self.client.containers.get(self._container_name(name))
        except NotFound:
            return None

    def _pull(self, image: str) -> None:
        """Pull ``image`` best-effort, splitting off an explicit tag if present."""
        repository = image
        tag: Optional[str] = None
        # Only treat a colon in the final path segment as a tag separator so we
        # do not mistake a registry ``host:port`` for a tag.
        last_segment = image.rsplit("/", 1)[-1]
        if ":" in last_segment:
            repository, tag = image.rsplit(":", 1)
        if tag is not None:
            self.client.images.pull(repository, tag=tag)
        else:
            self.client.images.pull(repository)

    # -- environment -------------------------------------------------------

    def env_for(self, inst: Instance) -> dict[str, str]:
        """Build the environment variables consumed by entrypoint.sh."""
        return {
            "INSTANCE": inst.name,
            "VISIBLE_HOSTNAME": inst.visible_hostname,
            "REALM": inst.realm,
            "AD_GROUP": inst.ad_group,
            "SCHOOL_SUBNETS": inst.school_subnets,
            "KEYTAB": f"/run/secrets/{inst.keytab_secret}",
            "CACHE_SIZE_MB": str(inst.cache_size_mb),
            "HTTP_PORT": str(inst.http_port),
            "LOG_RETENTION_DAYS": str(inst.log_retention_days),
            "ACCESS_LOG_ENABLED": "1" if inst.access_log_enabled else "0",
        }

    # -- lifecycle ---------------------------------------------------------

    def ensure_running(self, inst: Instance) -> dict[str, Any]:
        """Idempotently (re)create and start the container for ``inst``.

        Pulls the image, removes any existing ``lmnsquid-<name>`` container,
        then creates and starts a fresh one with the instance environment, the
        visible hostname, an ``unless-stopped`` restart policy and the keytab
        secret mounted read-only at the ``KEYTAB`` path.
        """
        try:
            self._pull(inst.image)
        except (ImageNotFound, docker.errors.APIError):
            # Fall back to a locally available image if the pull fails.
            pass

        existing = self._get(inst.name)
        if existing is not None:
            existing.remove(force=True)

        env = self.env_for(inst)
        keytab_container_path = env["KEYTAB"]
        # Defense in depth (the model already forbids '/'/'..'): resolve and assert
        # the keytab source stays inside secrets_dir before bind-mounting it.
        secrets_root = os.path.realpath(self.secrets_dir)
        keytab_host_path = os.path.realpath(os.path.join(secrets_root, inst.keytab_secret))
        if os.path.commonpath([secrets_root, keytab_host_path]) != secrets_root:
            raise ValueError(f"keytab_secret escapes secrets_dir: {inst.keytab_secret!r}")

        self.client.containers.run(
            inst.image,
            name=inst.container_name,
            hostname=inst.visible_hostname,
            environment=env,
            detach=True,
            restart_policy={"Name": "unless-stopped"},
            read_only=True,
            tmpfs={"/run": "", "/tmp": ""},
            cap_drop=["ALL"],
            cap_add=["SETUID", "SETGID", "DAC_OVERRIDE", "CHOWN"],
            security_opt=["no-new-privileges:true"],
            # Docker-json-log gedeckelt (nur der Live-Blick); die dauerhafte, gzip-rotierte
            # Historie liegt im persistenten Log-Volume (logrotate, LOG_RETENTION_DAYS).
            log_config=LogConfig(
                type="json-file",
                config={"max-size": self.log_max_size, "max-file": str(self.log_max_file)},
            ),
            volumes={
                keytab_host_path: {"bind": keytab_container_path, "mode": "ro"},
                f"lmnsquid-cache-{inst.name}": {"bind": "/var/spool/squid", "mode": "rw"},
                f"lmnsquid-logs-{inst.name}": {"bind": "/var/log/squid", "mode": "rw"},
            },
            ports={f"{inst.http_port}/tcp": (self.container_bind_ip, inst.http_port)},
        )
        return self.status(inst.name)

    def start(self, name: str) -> dict[str, Any]:
        container = self._get(name)
        if container is not None:
            container.start()
        return self.status(name)

    def stop(self, name: str) -> dict[str, Any]:
        container = self._get(name)
        if container is not None:
            container.stop()
        return self.status(name)

    def restart(self, name: str) -> dict[str, Any]:
        container = self._get(name)
        if container is not None:
            container.restart()
        return self.status(name)

    def remove(self, name: str) -> None:
        container = self._get(name)
        if container is not None:
            container.remove(force=True)

    # -- introspection -----------------------------------------------------

    def status(self, name: str) -> dict[str, Any]:
        """Return the current state of the container for ``name``."""
        container = self._get(name)
        if container is None:
            return {
                "name": name,
                "exists": False,
                "running": False,
                "health": None,
                "image": None,
            }

        container.reload()
        state: dict[str, Any] = container.attrs.get("State", {}) or {}
        running = bool(state.get("Running", False))

        health: Optional[str] = None
        health_state = state.get("Health")
        if isinstance(health_state, dict):
            status_value = health_state.get("Status")
            health = status_value if isinstance(status_value, str) else None

        image: Optional[str] = None
        image_obj = container.image
        if image_obj is not None and image_obj.tags:
            image = image_obj.tags[0]

        return {
            "name": name,
            "exists": True,
            "running": running,
            "health": health,
            "image": image,
        }

    def logs(self, name: str, tail: int = 100) -> str:
        """Return the last ``tail`` log lines of the container as text."""
        container = self._get(name)
        if container is None:
            return ""
        data = container.logs(tail=tail)
        if isinstance(data, bytes):
            return data.decode("utf-8", errors="replace")
        return str(data)
