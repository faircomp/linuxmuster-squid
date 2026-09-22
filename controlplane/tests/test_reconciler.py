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


def _inst(school: str, image: str) -> Instance:
    return Instance(
        school=school,
        role="teachers",
        ad_group="teachers",
        realm="EXAMPLE.LAN",
        visible_hostname=f"{school}.example.lan",
        keytab_secret=f"{school}.keytab",
        image=image,
    )


def test_reconcile_all_isolates_a_failing_instance(
    reconciler: Reconciler, store: Store, docker: Any
) -> None:
    # 'unpullable' makes the fake raise from ensure_running (like a missing image)
    store.put(_inst("a", "ghcr.io/example/lmnsquid:v1"))
    store.put(_inst("b", "ghcr.io/example/lmnsquid:unpullable"))
    store.put(_inst("c", "ghcr.io/example/lmnsquid:v1"))

    results = {r["name"]: r for r in reconciler.reconcile_all()}

    assert set(results) == {"a-teachers", "b-teachers", "c-teachers"}  # loop carried on
    assert results["a-teachers"]["running"] is True
    assert results["c-teachers"]["running"] is True
    assert "simulated pull failure" in results["b-teachers"]["error"]
    assert results["b-teachers"]["running"] is False


def test_a_failing_instance_keeps_its_running_container(
    reconciler: Reconciler, store: Store, docker: Any
) -> None:
    """The container of the instance that fails must survive (create-first replacement)."""
    healthy = _inst("a", "ghcr.io/example/lmnsquid:v1")
    broken = _inst("b", "ghcr.io/example/lmnsquid:v1")
    reconciler.apply(healthy)
    reconciler.apply(broken)
    before = dict(docker.containers["b-teachers"])

    # b is re-defined onto an image that cannot be brought up
    store.put(broken.model_copy(update={"image": "ghcr.io/example/lmnsquid:unpullable"}))
    results = {r["name"]: r for r in reconciler.reconcile_all()}

    assert "error" in results["b-teachers"]
    assert docker.containers["b-teachers"] == before  # old container untouched
    assert docker.containers["a-teachers"]["running"] is True  # the healthy one is fine
    assert results["a-teachers"]["running"] is True


def test_reconcile_reports_even_when_status_is_unavailable(
    reconciler: Reconciler, store: Store, docker: Any
) -> None:
    """A daemon that is down for status() too must not abort the whole run."""
    store.put(_inst("a", "ghcr.io/example/lmnsquid:unpullable"))
    store.put(_inst("b", "ghcr.io/example/lmnsquid:v1"))

    def boom(name: str) -> dict[str, Any]:
        raise RuntimeError("daemon gone")

    original = docker.status
    docker.status = boom
    try:
        results = {r["name"]: r for r in reconciler.reconcile_all()}
    finally:
        docker.status = original

    assert "simulated pull failure" in results["a-teachers"]["error"]
    assert results["a-teachers"]["exists"] is None
    assert "b-teachers" in results  # the loop carried on


def test_reconcile_api_and_cli_report_failures(
    client: Any, auth_headers: dict[str, str], store: Store, monkeypatch: Any
) -> None:
    from starlette.testclient import TestClient
    from typer.testing import CliRunner

    from lmnsquid import cli

    store.put(_inst("a", "ghcr.io/example/lmnsquid:v1"))
    store.put(_inst("b", "ghcr.io/example/lmnsquid:unpullable"))

    resp = client.post("/v1/reconcile", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["failed"] == ["b-teachers"]
    assert {r["name"] for r in resp.json()["reconciled"]} == {"a-teachers", "b-teachers"}

    def factory() -> TestClient:
        tc = TestClient(client.app)
        tc.headers.update(auth_headers)
        return tc

    monkeypatch.setattr(cli, "_get_client", factory)
    r = CliRunner().invoke(cli.app, ["reconcile"])
    assert r.exit_code == 1 and "b-teachers" in r.output

    store.delete("b-teachers")
    assert CliRunner().invoke(cli.app, ["reconcile"]).exit_code == 0


def test_update_all_cli_exits_nonzero_on_rollback(
    client: Any, auth_headers: dict[str, str], store: Store, monkeypatch: Any
) -> None:
    from starlette.testclient import TestClient
    from typer.testing import CliRunner

    from lmnsquid import api, cli

    store.put(_inst("a", "ghcr.io/example/lmnsquid:v1"))
    # a default image the fake reports as unhealthy -> every update rolls back
    monkeypatch.setattr(api, "DEFAULT_IMAGE", "ghcr.io/example/lmnsquid:bad")

    def factory() -> TestClient:
        tc = TestClient(client.app)
        tc.headers.update(auth_headers)
        return tc

    monkeypatch.setattr(cli, "_get_client", factory)
    r = CliRunner().invoke(cli.app, ["update-all"])
    assert r.exit_code == 1 and "a-teachers" in r.output
    assert store.get("a-teachers").image == "ghcr.io/example/lmnsquid:v1"  # type: ignore[union-attr]
