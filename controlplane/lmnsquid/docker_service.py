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

from .blocklist import CONTAINER_DIR, Blocklist
from .models import Instance

# The config entrypoint.sh renders and starts squid with (`squid -k` must read the same
# file to find pid_filename).
_SQUID_CONF = "/run/lmnsquid/squid.conf"


class DockerService:
    """Manage one Squid container per instance through the Docker Engine API.

    A container's real name is derived as ``lmnsquid-<name>`` where ``<name>``
    is the instance's :pyattr:`Instance.name` (``<school>-<role>``).
    """

    def __init__(
        self,
        docker_host: Optional[str] = None,
        secrets_dir: str = "/etc/linuxmuster-squid/secrets",
        container_bind_ip: str = "0.0.0.0",
        log_max_size: str = "20m",
        log_max_file: int = 5,
        blocklists_dir: str = "/etc/linuxmuster-squid/blocklists",
    ) -> None:
        self.docker_host: Optional[str] = docker_host
        self.secrets_dir: str = secrets_dir
        self.container_bind_ip: str = container_bind_ip
        self.log_max_size: str = log_max_size
        self.log_max_file: int = log_max_file
        self.blocklist = Blocklist(blocklists_dir)
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
        """Pull ``image`` best-effort, handling a ``@sha256:`` digest pin and a
        ``:tag`` (without mistaking a registry ``host:port`` for a tag)."""
        if "@" in image:
            # Digest pin ``repo@sha256:<hex>``: keep the whole ``sha256:<hex>`` as the
            # tag so docker-py pulls the digest (a plain ``rsplit(':')`` would drop the
            # ``sha256:`` prefix and pull a non-existent tag).
            repository, _, digest = image.partition("@")
            self.client.images.pull(repository, tag=digest)
            return
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
            "INTERNET_GROUP": inst.internet_group or "",
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
        visible hostname, an ``unless-stopped`` restart policy, the keytab
        secret mounted read-only at the ``KEYTAB`` path and the instance's
        blocklist directory mounted read-only at ``/etc/squid/lists``.
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
        # Blocklist: created empty if absent (create, reconcile, update all pass through
        # here, so instances from before 7.3.1 get the mount on their next recreate).
        blocklist_dir = os.path.realpath(self.blocklist.ensure(inst.name))

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
            # Docker json-log is capped (only the live view); the durable, gzip-rotated
            # history lives in the persistent log volume (logrotate, LOG_RETENTION_DAYS).
            log_config=LogConfig(
                type="json-file",
                config={"max-size": self.log_max_size, "max-file": str(self.log_max_file)},
            ),
            volumes={
                keytab_host_path: {"bind": keytab_container_path, "mode": "ro"},
                blocklist_dir: {"bind": CONTAINER_DIR, "mode": "ro"},
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

    def remove(self, name: str, keep_logs: bool = False) -> None:
        """Remove the container and everything the instance owns on this host.

        The cache volume is disposable and always goes; the log volume holds the
        access-log history (personal data, threat model T13) and goes unless
        ``keep_logs``; the blocklist directory goes with the definition.
        """
        container = self._get(name)
        if container is not None:
            container.remove(force=True)
        volumes = [f"lmnsquid-cache-{name}"]
        if not keep_logs:
            volumes.append(f"lmnsquid-logs-{name}")
        for volume in volumes:
            try:
                self.client.volumes.get(volume).remove(force=True)
            except NotFound:
                pass
        self.blocklist.delete(name)

    def reload(self, name: str) -> dict[str, Any]:
        """Make the running squid re-read squid.conf and its ACL list files (the blocklist).

        Runs ``squid -k reconfigure`` inside the container: squid parses the config and
        signals its running copy (SIGHUP). No restart -- the cache and open client
        connections survive, the auth/group helpers are restarted. Deliberately NOT
        ``container.kill(signal="SIGHUP")``: Docker records every kill(), whatever the
        signal, as a manual stop, and an ``unless-stopped`` container is then no longer
        started after a reboot (seen in the lab). Like ``access_logs`` this needs
        ``docker exec`` (not available behind the socket proxy with ``EXEC: 0``).
        Raises ``LookupError`` when there is no running container, ``RuntimeError``
        when squid refuses.
        """
        container = self._get(name)
        if container is None:
            raise LookupError(f"instance {name!r} has no container")
        container.reload()
        state: dict[str, Any] = container.attrs.get("State", {}) or {}
        if not state.get("Running", False):
            raise LookupError(f"instance {name!r} is not running")
        exit_code, output = container.exec_run(["squid", "-k", "reconfigure", "-f", _SQUID_CONF])
        text = (
            output.decode("utf-8", errors="replace") if isinstance(output, bytes) else str(output)
        )
        if exit_code != 0:
            raise RuntimeError(f"squid -k reconfigure exited {exit_code}: {text.strip()}")
        return {"name": name, "reloaded": True}

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

    def logs(
        self,
        name: str,
        tail: int = 100,
        since: Optional[int] = None,
        until: Optional[int] = None,
        grep: Optional[str] = None,
    ) -> str:
        """Return the last ``tail`` lines of the live docker log (access + squid debug).

        ``since``/``until`` are Unix epoch seconds; ``grep`` is a plain substring filter
        applied in Python (no shell — injection-safe).
        """
        container = self._get(name)
        if container is None:
            return ""
        kwargs: dict[str, Any] = {"tail": tail}
        if since is not None:
            kwargs["since"] = since
        if until is not None:
            kwargs["until"] = until
        data = container.logs(**kwargs)
        text = data.decode("utf-8", errors="replace") if isinstance(data, bytes) else str(data)
        if grep:
            text = "\n".join(line for line in text.splitlines() if grep in line)
        return text

    def access_logs(
        self,
        name: str,
        since: Optional[int] = None,
        until: Optional[int] = None,
        grep: Optional[str] = None,
        tail: int = 200,
    ) -> str:
        """Query the retained (gzip-rotated) access-log history in the log volume.

        Reads every ``access.log*`` file (current + rotated ``.gz``) inside the container
        and filters by epoch window + substring. User input is passed via the exec
        environment, NEVER interpolated into the shell string (no command injection).
        """
        container = self._get(name)
        if container is None:
            return ""
        env = {"SINCE": str(since or ""), "UNTIL": str(until or ""), "GREP": grep or ""}
        script = (
            "zcat -f /var/log/squid/access.log* 2>/dev/null"
            ' | awk \'(!ENVIRON["SINCE"] || $1+0 >= ENVIRON["SINCE"]+0)'
            ' && (!ENVIRON["UNTIL"] || $1+0 <= ENVIRON["UNTIL"]+0)\''
            ' | { if [ -n "$GREP" ]; then grep -F -- "$GREP"; else cat; fi; }'
            f" | tail -n {int(tail)}"
        )
        _exit_code, output = container.exec_run(["sh", "-c", script], environment=env)
        if isinstance(output, bytes):
            return output.decode("utf-8", errors="replace")
        return str(output or "")
