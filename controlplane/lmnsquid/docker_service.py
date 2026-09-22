# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Docker orchestration for linuxmuster-squid instances via the docker-py SDK."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from typing import Any, Optional

import docker
from docker.errors import APIError, ImageNotFound, NotFound
from docker.models.containers import Container
from docker.types import LogConfig

from .blocklist import CONTAINER_DIR, Blocklist
from .models import Instance

logger = logging.getLogger("lmnsquid.docker")

# The config entrypoint.sh renders and starts squid with (`squid -k` must read the same
# file to find pid_filename).
_SQUID_CONF = "/run/lmnsquid/squid.conf"
# Container label carrying the fingerprint of everything the container was created
# from; a container whose label matches the desired spec is left alone by
# ensure_running (reconcile is a no-op for it), one without or with another
# fingerprint is replaced.
SPEC_LABEL = "lmnsquid.spec"


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
        health_timeout: float = 90.0,
        poll_interval: float = 2.0,
    ) -> None:
        self.docker_host: Optional[str] = docker_host
        self.secrets_dir: str = secrets_dir
        self.container_bind_ip: str = container_bind_ip
        self.log_max_size: str = log_max_size
        self.log_max_file: int = log_max_file
        self.blocklist = Blocklist(blocklists_dir)
        self.health_timeout = health_timeout
        self.poll_interval = poll_interval
        self.client: docker.DockerClient = (
            docker.DockerClient(base_url=docker_host) if docker_host else docker.from_env()
        )

    # -- helpers -----------------------------------------------------------

    @staticmethod
    def _container_name(name: str) -> str:
        return f"lmnsquid-{name}"

    def _get(self, name: str) -> Optional[Container]:
        """Return the container for ``name`` or ``None`` if it does not exist."""
        return self._get_raw(self._container_name(name))

    def _get_raw(self, container_name: str) -> Optional[Container]:
        try:
            return self.client.containers.get(container_name)
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

    def spec_for(self, inst: Instance) -> dict[str, Any]:
        """Everything the container is created from (JSON-able), except its name.

        Its fingerprint goes into the ``lmnsquid.spec`` label, so the same spec is
        recognised as "already running as desired" and anything else (new field, new
        mount, moved image) triggers a replacement.
        """
        env = self.env_for(inst)
        # Defense in depth (the model already forbids '/'/'..'): resolve and assert
        # the keytab source stays inside secrets_dir before bind-mounting it.
        secrets_root = os.path.realpath(self.secrets_dir)
        keytab_host_path = os.path.realpath(os.path.join(secrets_root, inst.keytab_secret))
        if os.path.commonpath([secrets_root, keytab_host_path]) != secrets_root:
            raise ValueError(f"keytab_secret escapes secrets_dir: {inst.keytab_secret!r}")
        return {
            "image": inst.image,
            "hostname": inst.visible_hostname,
            "environment": env,
            "restart_policy": {"Name": "unless-stopped"},
            "read_only": True,
            "tmpfs": {"/run": "", "/tmp": ""},
            "cap_drop": ["ALL"],
            "cap_add": ["SETUID", "SETGID", "DAC_OVERRIDE", "CHOWN"],
            "security_opt": ["no-new-privileges:true"],
            # Docker json-log is capped (only the live view); the durable, gzip-rotated
            # history lives in the persistent log volume (logrotate, LOG_RETENTION_DAYS).
            "log_config": {"max-size": self.log_max_size, "max-file": str(self.log_max_file)},
            "volumes": {
                keytab_host_path: {"bind": env["KEYTAB"], "mode": "ro"},
                # Per-instance blocklist directory (see blocklist.py for why the directory).
                os.path.realpath(self.blocklist.dir_for(inst.name)): {
                    "bind": CONTAINER_DIR,
                    "mode": "ro",
                },
                f"lmnsquid-cache-{inst.name}": {"bind": "/var/spool/squid", "mode": "rw"},
                f"lmnsquid-logs-{inst.name}": {"bind": "/var/log/squid", "mode": "rw"},
            },
            "ports": {f"{inst.http_port}/tcp": [self.container_bind_ip, inst.http_port]},
        }

    @staticmethod
    def fingerprint(spec: dict[str, Any]) -> str:
        return hashlib.sha256(json.dumps(spec, sort_keys=True).encode("utf-8")).hexdigest()

    # -- lifecycle ---------------------------------------------------------

    def ensure_running(self, inst: Instance) -> dict[str, Any]:
        """Make the container for ``inst`` match its definition and run.

        A container that already carries the fingerprint of the desired spec is only
        started if stopped -- so `reconcile`, an `edit` without effective change and
        an `update` to the same image touch nothing. Otherwise the container is
        REPLACED without a gap for failure: the new one is created first (the old one
        keeps serving), the old one is stopped and parked, the new one started and
        health-gated; if it does not become healthy the new one is removed and the old
        one restarted, and a ``RuntimeError`` says so. Only a healthy replacement
        removes the previous container.
        """
        try:
            self._pull(inst.image)
        except (ImageNotFound, APIError):
            # Fall back to a locally available image if the pull fails.
            pass

        spec = self.spec_for(inst)
        digest = self.fingerprint(spec)
        # Blocklist: created empty if absent (create, reconcile, update all pass through
        # here, so instances from before 7.3.1 get the mount on their next replacement).
        self.blocklist.ensure(inst.name)

        cname = inst.container_name
        existing = self._get(inst.name)
        if existing is not None and existing.labels.get(SPEC_LABEL) == digest:
            existing.reload()
            if not (existing.attrs.get("State") or {}).get("Running", False):
                existing.start()
            return self.status(inst.name)

        # Leftovers of an interrupted replacement.
        for suffix in (".new", ".old"):
            stale = self._get_raw(f"{cname}{suffix}")
            if stale is not None:
                stale.remove(force=True)

        # Create first: an unpullable image, a full disk or a daemon error leaves the
        # old container untouched and still serving.
        new = self.client.containers.create(
            spec["image"],
            name=f"{cname}.new",
            hostname=spec["hostname"],
            environment=spec["environment"],
            restart_policy=spec["restart_policy"],
            read_only=spec["read_only"],
            tmpfs=spec["tmpfs"],
            cap_drop=spec["cap_drop"],
            cap_add=spec["cap_add"],
            security_opt=spec["security_opt"],
            log_config=LogConfig(type="json-file", config=spec["log_config"]),
            volumes=spec["volumes"],
            ports={k: tuple(v) for k, v in spec["ports"].items()},
            labels={SPEC_LABEL: digest},
        )
        if existing is not None:
            try:
                # Free the host port; a short grace lets squid flush its logs.
                existing.stop(timeout=3)
                existing.rename(f"{cname}.old")
            except APIError:
                # The swap never started: drop the spare instead of leaving a
                # half-renamed pair behind, and let the caller see the daemon error.
                new.remove(force=True)
                raise

        reason: Optional[str]
        try:
            new.rename(cname)
            new.start()
            reason = self._wait_healthy(new)
        except APIError as exc:
            reason = f"start failed: {exc}"
        if reason is None:
            if existing is not None:
                existing.remove(force=True)
            return self.status(inst.name)

        # Not healthy: put the previous container back before reporting.
        logger.error("new container for %s failed (%s)", inst.name, reason)
        new.remove(force=True)
        restored = ""
        if existing is not None:
            existing.rename(cname)
            try:
                existing.start()
                restored = "; previous container restored"
            except APIError as exc:
                restored = f"; previous container could NOT be restarted: {exc}"
        raise RuntimeError(
            f"container for {inst.name!r} did not become healthy: {reason}{restored}"
        )

    def _wait_healthy(self, container: Container) -> Optional[str]:
        """Return ``None`` once ``container`` is healthy, else why it is not.

        Fails fast when the process exits; an image without a HEALTHCHECK counts as
        healthy as soon as it runs.
        """
        config = container.attrs.get("Config") or {}
        test = (config.get("Healthcheck") or {}).get("Test") or []
        has_check = bool(test) and test != ["NONE"]
        deadline = time.monotonic() + self.health_timeout
        while True:
            container.reload()
            state: dict[str, Any] = container.attrs.get("State") or {}
            if not state.get("Running", False):
                return f"exited with code {state.get('ExitCode')}"
            health = (state.get("Health") or {}).get("Status")
            if health == "healthy" or (not has_check and health is None):
                return None
            if health == "unhealthy":
                return "unhealthy"
            if time.monotonic() >= deadline:
                return f"not healthy after {self.health_timeout:.0f}s (status {health})"
            time.sleep(self.poll_interval)

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
            except APIError as exc:
                # e.g. still in use by a foreign container: the definition must still
                # go; the volume can be removed by hand.
                logger.warning("volume %s not removed: %s", volume, exc)
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
        when the exec is refused or squid does.
        """
        container = self._get(name)
        if container is None:
            raise LookupError(f"instance {name!r} has no container")
        container.reload()
        state: dict[str, Any] = container.attrs.get("State", {}) or {}
        if not state.get("Running", False):
            raise LookupError(f"instance {name!r} is not running")
        try:
            exit_code, output = container.exec_run(
                ["squid", "-k", "reconfigure", "-f", _SQUID_CONF]
            )
        except APIError as exc:
            # The daemon is alive; exec itself was refused (socket proxy with EXEC: 0).
            raise RuntimeError(
                f"docker exec refused ({exc.explanation or exc}); blocklist reload needs "
                "EXEC at the docker socket proxy (ADR-012/ADR-014)"
            ) from exc
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
