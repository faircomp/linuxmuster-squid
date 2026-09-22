# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reconcile desired instance state (store) with runtime state (Docker)."""

from __future__ import annotations

import logging

from .docker_service import DockerService
from .models import Instance
from .store import Store

logger = logging.getLogger("lmnsquid.reconciler")


class Reconciler:
    """Bridge the persistent :class:`Store` and the live :class:`DockerService`."""

    def __init__(self, store: Store, docker: DockerService) -> None:
        self.store = store
        self.docker = docker

    def apply(self, inst: Instance) -> dict:
        """Persist ``inst`` then make its container match and run."""
        self.store.put(inst)
        return self.docker.ensure_running(inst)

    def remove(self, name: str, keep_logs: bool = False) -> None:
        """Remove the container (+ volumes, blocklist) then delete the instance from the store."""
        self.docker.remove(name, keep_logs=keep_logs)
        self.store.delete(name)

    def reconcile_all(self) -> list[dict]:
        """Ensure every stored instance runs as defined; return their statuses.

        One instance failing (unpullable image, broken definition, daemon error) must
        not stop the others from being reconciled: its status carries an ``error``
        and the loop carries on. The API/CLI surface the failed names.
        """
        statuses: list[dict] = []
        for inst in self.store.list():
            try:
                statuses.append(self.docker.ensure_running(inst))
            except Exception as exc:  # noqa: BLE001 - isolate per instance, report below
                logger.error("reconcile failed name=%s: %s", inst.name, exc)
                statuses.append({**self._status_or_unknown(inst.name), "error": str(exc)})
        return statuses

    def _status_or_unknown(self, name: str) -> dict:
        """Status of ``name``, or a placeholder — reporting a failure must not fail too."""
        try:
            return self.docker.status(name)
        except Exception as exc:  # noqa: BLE001 - the daemon may be the reason we are here
            logger.error("status unavailable name=%s: %s", name, exc)
            return {"name": name, "exists": None, "running": False, "health": None, "image": None}
