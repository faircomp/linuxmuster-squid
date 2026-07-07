# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""FastAPI application factory for the linuxmuster-squid control plane."""

from __future__ import annotations

import logging
import re
from typing import Any

from docker.errors import DockerException
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse

from .config import Settings
from .docker_service import DockerService
from .models import DEFAULT_IMAGE, Instance, InstancePatch, UpdateRequest
from .reconciler import Reconciler
from .security import make_verify_token
from .store import Store
from .updater import Updater

audit = logging.getLogger("lmnsquid.audit")

# {name} path param flows into Store filenames + docker names; require a safe school-role name.
_NAME_PARAM_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{1,62}$")


def create_app(
    settings: Settings,
    store: Store,
    reconciler: Reconciler,
    docker: DockerService,
    updater: Updater,
) -> FastAPI:
    """Build the FastAPI app wiring routes to the store, reconciler and docker service."""
    verify = make_verify_token(settings)
    app = FastAPI(title="linuxmuster-squid control plane")

    @app.exception_handler(DockerException)
    async def _docker_unreachable(_request: Request, exc: DockerException) -> JSONResponse:
        # Docker daemon down / Engine-API error -> 503 with a clear detail, not a raw 500.
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"detail": f"docker daemon unreachable: {exc}"},
        )

    auth = [Depends(verify)]

    def _require(name: str) -> Instance:
        if not _NAME_PARAM_RE.match(name):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="invalid instance name",
            )
        inst = store.get(name)
        if inst is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"instance {name!r} not found",
            )
        return inst

    def _check_log_params(tail: int, grep: str | None) -> None:
        if not 1 <= tail <= 10000:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="tail must be between 1 and 10000",
            )
        if grep is not None and len(grep) > 200:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="grep pattern too long (max 200 chars)",
            )

    # ------------------------------------------------------------------ health
    @app.get("/v1/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/version", dependencies=auth)
    async def version() -> dict[str, str]:
        return {"version": settings.version}

    # NOTE: the endpoints below do blocking docker-py / health-poll work; they are
    # plain `def` so FastAPI runs them in a threadpool instead of stalling the event
    # loop (an `update-all` can otherwise hold it for minutes and hang /v1/health).
    @app.post("/v1/reconcile", dependencies=auth)
    def reconcile() -> dict[str, Any]:
        """Re-apply every stored instance (reconverge drift / restore on a fresh host)."""
        audit.info("reconcile all instances")
        return {"reconciled": reconciler.reconcile_all()}

    @app.post("/v1/update-all", dependencies=auth)
    def update_all() -> dict[str, Any]:
        """Lift every instance onto the maintained default image (per-instance rollback)."""
        audit.info("update-all to default image=%s", DEFAULT_IMAGE)
        return {"results": updater.update_all(DEFAULT_IMAGE)}

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
        # Re-validate the merged instance through Instance validators; school/role
        # are not in InstancePatch, so the identity/name stays immutable.
        merged = Instance.model_validate(
            {**existing.model_dump(exclude={"name", "container_name"}), **updates}
        )
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
    async def instance_logs(
        name: str,
        tail: int = 100,
        since: int | None = None,
        until: int | None = None,
        grep: str | None = None,
    ) -> dict[str, str]:
        _require(name)
        _check_log_params(tail, grep)
        return {"logs": docker.logs(name, tail=tail, since=since, until=until, grep=grep)}

    @app.get("/v1/instances/{name}/logs/access", dependencies=auth)
    async def instance_access_logs(
        name: str,
        tail: int = 200,
        since: int | None = None,
        until: int | None = None,
        grep: str | None = None,
    ) -> dict[str, str]:
        """Query the retained (gzip-rotated) access-log history in the log volume."""
        _require(name)
        _check_log_params(tail, grep)
        return {
            "logs": docker.access_logs(name, since=since, until=until, grep=grep, tail=tail)
        }

    # ---------------------------------------------------- digest-pinned updates
    @app.post("/v1/instances/{name}/update", dependencies=auth)
    def update_instance(name: str, body: UpdateRequest) -> dict[str, Any]:
        _require(name)
        audit.info("update request name=%s image=%s", name, body.image)
        return updater.update(name, body.image)

    @app.post("/v1/instances/{name}/rollback", dependencies=auth)
    def rollback_instance(name: str) -> dict[str, Any]:
        _require(name)
        audit.info("rollback request name=%s", name)
        try:
            return updater.rollback(name)
        except FileNotFoundError as exc:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail=str(exc)
            ) from exc

    return app
