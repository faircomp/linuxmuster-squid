# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Digest-pinned image updates with health-check driven auto-rollback.

Updating a running proxy at a school is risky: a bad image means every client
loses internet. So an update always records the previous (known-good) image,
applies the new one, waits for the container to become *healthy*, and rolls
back automatically if it does not.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import Any

from .docker_service import DockerService
from .reconciler import Reconciler
from .store import Store

audit = logging.getLogger("lmnsquid.audit")


class Updater:
    """Perform health-gated, auto-rolling image updates for an instance."""

    def __init__(
        self,
        store: Store,
        docker: DockerService,
        reconciler: Reconciler,
        health_timeout: float = 90.0,
        poll_interval: float = 3.0,
    ) -> None:
        self.store = store
        self.docker = docker
        self.reconciler = reconciler
        self.health_timeout = health_timeout
        self.poll_interval = poll_interval

    def _prev_file(self, name: str) -> Path:
        # Lives beside the yaml files; Store.list() only globs *.yaml so this is ignored there.
        return self.store.path / f"{name}.prev"

    def update(self, name: str, new_image: str) -> dict[str, Any]:
        """Update ``name`` to ``new_image``; auto-rollback if it does not turn healthy."""
        inst = self.store.get(name)
        if inst is None:
            raise KeyError(name)

        previous_image = inst.image
        self._prev_file(name).write_text(previous_image, encoding="utf-8")
        audit.info("update start name=%s from=%s to=%s", name, previous_image, new_image)

        self.reconciler.apply(inst.model_copy(update={"image": new_image}))
        if self._wait_healthy(name):
            audit.info("update ok name=%s image=%s", name, new_image)
            return {
                "name": name,
                "updated": True,
                "image": new_image,
                "previous_image": previous_image,
            }

        # Not healthy in time -> restore the known-good image.
        audit.warning("update unhealthy name=%s -> rollback to %s", name, previous_image)
        self.reconciler.apply(inst)  # inst still carries previous_image
        return {
            "name": name,
            "updated": False,
            "rolled_back_to": previous_image,
            "failed_image": new_image,
        }

    def rollback(self, name: str) -> dict[str, Any]:
        """Revert ``name`` to the image recorded before the last update."""
        inst = self.store.get(name)
        if inst is None:
            raise KeyError(name)
        prev_file = self._prev_file(name)
        if not prev_file.is_file():
            raise FileNotFoundError(f"no previous image recorded for {name}")
        previous_image = prev_file.read_text(encoding="utf-8").strip()
        audit.info("rollback name=%s to=%s", name, previous_image)
        self.reconciler.apply(inst.model_copy(update={"image": previous_image}))
        return {"name": name, "rolled_back_to": previous_image}

    def _wait_healthy(self, name: str) -> bool:
        deadline = time.monotonic() + self.health_timeout
        while True:
            health = self.docker.status(name).get("health")
            if health == "healthy":
                return True
            if health == "unhealthy":
                return False
            if time.monotonic() >= deadline:
                return False
            time.sleep(self.poll_interval)
