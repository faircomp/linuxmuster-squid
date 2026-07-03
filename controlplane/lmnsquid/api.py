# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""FastAPI application factory for the linuxmuster-squid control plane."""

from __future__ import annotations

import logging
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, status

from .config import Settings
from .docker_service import DockerService
from .models import Instance, InstancePatch
from .reconciler import Reconciler
from .security import make_verify_token
from .store import Store

audit = logging.getLogger("lmnsquid.audit")


def create_app(
    settings: Settings,
    store: Store,
    reconciler: Reconciler,
    docker: DockerService,
) -> FastAPI:
    """Build the FastAPI app wiring routes to the store, reconciler and docker service."""
    verify = make_verify_token(settings)
    app = FastAPI(title="linuxmuster-squid control plane")

    auth = [Depends(verify)]

    def _require(name: str) -> Instance:
        inst = store.get(name)
        if inst is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"instance {name!r} not found",
            )
        return inst

    # ------------------------------------------------------------------ health
    @app.get("/v1/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/version", dependencies=auth)
    async def version() -> dict[str, str]:
        return {"version": settings.version}

    # --------------------------------------------------------------- instances
    @app.post(
        "/v1/instances",
        dependencies=auth,
        status_code=status.HTTP_201_CREATED,
    )
    async def create_instance(inst: Instance) -> dict[str, Any]:
        result = reconciler.apply(inst)
        audit.info("create instance name=%s image=%s", inst.name, inst.image)
        return {"instance": inst, "status": result}

    @app.get("/v1/instances", dependencies=auth)
    async def list_instances() -> list[Instance]:
        return store.list()

    @app.get("/v1/instances/{name}", dependencies=auth)
    async def get_instance(name: str) -> Instance:
        return _require(name)

    @app.patch("/v1/instances/{name}", dependencies=auth)
    async def patch_instance(name: str, patch: InstancePatch) -> dict[str, Any]:
        existing = _require(name)
        updates = patch.model_dump(exclude_unset=True)
        merged = existing.model_copy(update=updates)
        result = reconciler.apply(merged)
        audit.info(
            "patch instance name=%s fields=%s",
            merged.name,
            sorted(updates.keys()),
        )
        return {"instance": merged, "status": result}

    @app.delete(
        "/v1/instances/{name}",
        dependencies=auth,
        status_code=status.HTTP_204_NO_CONTENT,
    )
    async def delete_instance(name: str) -> None:
        _require(name)
        reconciler.remove(name)
        audit.info("delete instance name=%s", name)

    # ----------------------------------------------------------- lifecycle ops
    @app.post("/v1/instances/{name}/start", dependencies=auth)
    async def start_instance(name: str) -> dict[str, Any]:
        _require(name)
        audit.info("start instance name=%s", name)
        return docker.start(name)

    @app.post("/v1/instances/{name}/stop", dependencies=auth)
    async def stop_instance(name: str) -> dict[str, Any]:
        _require(name)
        audit.info("stop instance name=%s", name)
        return docker.stop(name)

    @app.post("/v1/instances/{name}/restart", dependencies=auth)
    async def restart_instance(name: str) -> dict[str, Any]:
        _require(name)
        audit.info("restart instance name=%s", name)
        return docker.restart(name)

    @app.get("/v1/instances/{name}/status", dependencies=auth)
    async def instance_status(name: str) -> dict[str, Any]:
        _require(name)
        return docker.status(name)

    @app.get("/v1/instances/{name}/logs", dependencies=auth)
    async def instance_logs(name: str, tail: int = 100) -> dict[str, str]:
        _require(name)
        return {"logs": docker.logs(name, tail=tail)}

    return app
