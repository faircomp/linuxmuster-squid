# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Updater: digest-pinned update with health-check auto-rollback (fake docker)."""

from __future__ import annotations

from typing import Any

from lmnsquid.models import Instance
from lmnsquid.reconciler import Reconciler
from lmnsquid.store import Store
from lmnsquid.updater import Updater

# The FakeDockerService (conftest) reports a container as "unhealthy" when the
# image name contains "bad", otherwise "healthy".
GOOD_V2 = "ghcr.io/example/lmnsquid:v2"
BAD = "ghcr.io/example/lmnsquid:bad"


def _updater(store: Store, docker: Any, reconciler: Reconciler) -> Updater:
    return Updater(store, docker, reconciler, health_timeout=1.0, poll_interval=0.0)


def test_update_success_pins_new_image(
    store: Store, docker: Any, reconciler: Reconciler, instance: Instance
) -> None:
    reconciler.apply(instance)  # baseline (healthy)
    up = _updater(store, docker, reconciler)

    res = up.update(instance.name, GOOD_V2)

    assert res["updated"] is True
    assert res["image"] == GOOD_V2
    assert store.get(instance.name).image == GOOD_V2  # type: ignore[union-attr]


def test_update_bad_image_auto_rolls_back(
    store: Store, docker: Any, reconciler: Reconciler, instance: Instance
) -> None:
    reconciler.apply(instance)
    good = instance.image
    up = _updater(store, docker, reconciler)

    res = up.update(instance.name, BAD)

    assert res["updated"] is False
    assert res["rolled_back_to"] == good
    # store reverted to the known-good image and the container is healthy again
    assert store.get(instance.name).image == good  # type: ignore[union-attr]
    assert docker.status(instance.name)["health"] == "healthy"


def test_explicit_rollback(
    store: Store, docker: Any, reconciler: Reconciler, instance: Instance
) -> None:
    reconciler.apply(instance)
    good = instance.image
    up = _updater(store, docker, reconciler)
    up.update(instance.name, GOOD_V2)  # records prev=good, pins v2

    res = up.rollback(instance.name)

    assert res["rolled_back_to"] == good
    assert store.get(instance.name).image == good  # type: ignore[union-attr]


def test_update_endpoint(client: Any, auth_headers: dict[str, str], instance_data: dict[str, Any]) -> None:
    client.post("/v1/instances", json=instance_data, headers=auth_headers)
    resp = client.post(
        "/v1/instances/default-school-teachers/update",
        json={"image": GOOD_V2},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    assert resp.json()["updated"] is True


def test_update_all_lifts_stale_and_skips_current(
    store: Store, docker: Any, reconciler: Reconciler
) -> None:
    from lmnsquid.models import DEFAULT_IMAGE

    def _inst(school: str, role: str, image: str) -> Instance:
        return Instance(
            school=school,
            role=role,
            ad_group=role,
            realm="EX.LAN",
            visible_hostname=f"{school}-{role}.example.lan",
            keytab_secret=f"{school}-{role}.keytab",
            image=image,
        )

    reconciler.apply(_inst("a", "teachers", "ghcr.io/example/lmnsquid:v1"))  # stale
    reconciler.apply(_inst("b", "students", DEFAULT_IMAGE))                  # already current
    up = _updater(store, docker, reconciler)

    results = {r["name"]: r for r in up.update_all(DEFAULT_IMAGE)}

    assert results["a-teachers"]["updated"] is True
    assert store.get("a-teachers").image == DEFAULT_IMAGE  # type: ignore[union-attr]
    assert results["b-students"].get("skipped") is True    # untouched (no recreate)
    assert store.get("b-students").image == DEFAULT_IMAGE   # type: ignore[union-attr]
