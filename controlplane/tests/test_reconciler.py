# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for :class:`lmnsquid.reconciler.Reconciler` against the fake backend."""

from __future__ import annotations

from typing import Any

from lmnsquid.models import Instance
from lmnsquid.reconciler import Reconciler
from lmnsquid.store import Store

# ``docker`` is the FakeDockerService instance from conftest; annotated as Any
# to avoid a cross-module import of a test helper.


def test_apply_persists_and_ensures_running(
    reconciler: Reconciler,
    store: Store,
    docker: Any,
    instance: Instance,
) -> None:
    status = reconciler.apply(instance)

    # persisted to the store
    persisted = store.get(instance.name)
    assert persisted is not None
    assert persisted.name == instance.name

    # ensure_running was invoked and reported a running container
    assert docker.ensure_calls == [instance.name]
    assert status["exists"] is True
    assert status["running"] is True


def test_remove_stops_docker_and_deletes_store(
    reconciler: Reconciler,
    store: Store,
    docker: Any,
    instance: Instance,
) -> None:
    reconciler.apply(instance)
    assert store.get(instance.name) is not None

    reconciler.remove(instance.name)

    assert instance.name in docker.removed
    assert store.get(instance.name) is None
    assert instance.name not in docker.containers


def test_reconcile_all_ensures_every_stored_instance(
    reconciler: Reconciler,
    store: Store,
    docker: Any,
    instance: Instance,
) -> None:
    second = Instance(
        school="schuleB",
        role="students",
        ad_group="students",
        realm="EXAMPLE.LAN",
        visible_hostname="proxy-b.example.lan",
        keytab_secret="schuleB-students.keytab",
        image="ghcr.io/example/lmnsquid:latest",
    )
    store.put(instance)
    store.put(second)

    docker.ensure_calls.clear()
    results = reconciler.reconcile_all()

    assert len(results) == 2
    assert set(docker.ensure_calls) == {instance.name, second.name}
    assert all(r["running"] is True for r in results)
