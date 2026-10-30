# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Integration test: the REAL DockerService manages a real Squid container.

Skipped unless ``LMNSQUID_DOCKER_IT=1`` (needs a reachable Docker daemon and the
``linuxmuster-squid:dev`` image). Driven on crabbox by ``run.sh e2e``.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("LMNSQUID_DOCKER_IT") != "1",
    reason="set LMNSQUID_DOCKER_IT=1 (needs Docker + linuxmuster-squid:dev image)",
)

IMAGE = os.environ.get("LMNSQUID_IT_IMAGE", "linuxmuster-squid:dev")


def test_real_container_lifecycle(tmp_path: Path) -> None:
    from lmnsquid.docker_service import DockerService
    from lmnsquid.models import Instance

    secrets = tmp_path / "secrets"
    secrets.mkdir()
    # A readable (bogus) keytab so entrypoint.sh proceeds; Kerberos itself is
    # exercised by the compose E2E, not here — this proves docker-py lifecycle.
    (secrets / "it.keytab").write_bytes(b"dummy-keytab-not-valid")

    lists = tmp_path / "lists"
    svc = DockerService(secrets_dir=str(secrets), blocklists_dir=str(lists))
    inst = Instance(
        school="it",
        role="teachers",
        ad_group="teachers",
        realm="EXAMPLE.INTERNAL",
        visible_hostname="squid-it.example.internal",
        http_port=3199,
        school_subnets="0.0.0.0/0",
        keytab_secret="it.keytab",
        cache_size_mb=100,
        image=IMAGE,
    )

    svc.remove(inst.name)  # clean slate
    try:
        created = svc.ensure_running(inst)
        assert created["exists"] is True
        assert created["running"] is True

        # Squid must still be up a few seconds later (did not crash on boot).
        time.sleep(5)
        assert svc.status(inst.name)["running"] is True

        # ADR-016: noauth.domains exists before the start, so this image reads it, and a
        # reload picks up an entry added afterwards.
        assert (lists / inst.name / "noauth.domains").read_text() == ""
        assert svc.noauth_active(inst.name) is True
        svc.noauth.add(inst.name, "office.com")
        assert svc.reload(inst.name) == {"name": inst.name, "reloaded": True}

        assert svc.stop(inst.name)["running"] is False
        assert svc.start(inst.name)["running"] is True
    finally:
        svc.remove(inst.name)

    assert svc.status(inst.name)["exists"] is False


def test_real_update_auto_rollback(tmp_path: Path) -> None:
    """Updating to a broken image (which crashes) must auto-roll-back to the good one."""
    from lmnsquid.docker_service import DockerService
    from lmnsquid.models import Instance
    from lmnsquid.reconciler import Reconciler
    from lmnsquid.store import Store
    from lmnsquid.updater import Updater

    bad_image = os.environ.get("LMNSQUID_IT_BAD_IMAGE", "linuxmuster-squid:broken")
    secrets = tmp_path / "secrets"
    secrets.mkdir()
    (secrets / "it.keytab").write_bytes(b"dummy-keytab-not-valid")

    store = Store(str(tmp_path / "instances"))
    docker = DockerService(secrets_dir=str(secrets), blocklists_dir=str(tmp_path / "lists"))
    reconciler = Reconciler(store, docker)
    updater = Updater(store, docker, reconciler, health_timeout=45.0, poll_interval=2.0)

    inst = Instance(
        school="itr",
        role="teachers",
        ad_group="teachers",
        realm="EXAMPLE.INTERNAL",
        visible_hostname="squid-itr.example.internal",
        http_port=3198,
        school_subnets="0.0.0.0/0",
        keytab_secret="it.keytab",
        cache_size_mb=100,
        image=IMAGE,
    )

    docker.remove(inst.name)
    try:
        reconciler.apply(inst)  # good image, starts
        res = updater.update(inst.name, bad_image)  # broken exits -> fail fast -> rollback
        assert res["updated"] is False
        assert res["rolled_back_to"] == IMAGE
        time.sleep(3)
        assert docker.status(inst.name)["running"] is True  # good image restored
        assert store.get(inst.name).image == IMAGE  # type: ignore[union-attr]
    finally:
        docker.remove(inst.name)


def test_real_pinned_image_ignores_the_noauth_list(tmp_path: Path) -> None:
    """The image installed systems run (DEFAULT_IMAGE) next to a list directory with
    noauth.domains: it starts healthy, and the noauth reload is refused instead of
    reporting a reload that changes nothing (ADR-016)."""
    from lmnsquid.docker_service import DockerService
    from lmnsquid.models import DEFAULT_IMAGE, Instance

    old_image = os.environ.get("LMNSQUID_IT_OLD_IMAGE", DEFAULT_IMAGE)
    secrets = tmp_path / "secrets"
    secrets.mkdir()
    (secrets / "it.keytab").write_bytes(b"dummy-keytab-not-valid")
    lists = tmp_path / "lists"
    svc = DockerService(secrets_dir=str(secrets), blocklists_dir=str(lists))
    inst = Instance(
        school="ito",
        role="teachers",
        ad_group="teachers",
        realm="EXAMPLE.INTERNAL",
        visible_hostname="squid-ito.example.internal",
        http_port=3197,
        school_subnets="0.0.0.0/0",
        keytab_secret="it.keytab",
        cache_size_mb=100,
        image=old_image,
    )
    svc.remove(inst.name)
    svc.noauth.add(inst.name, "office.com")  # a list that is there before the container
    try:
        status = svc.ensure_running(inst)  # health-gated: raises if it does not come up
        assert status["running"] is True and status["health"] == "healthy"
        assert svc.noauth_active(inst.name) is False
        assert svc.reload(inst.name)["reloaded"] is True  # the blocklist reload still works
    finally:
        svc.remove(inst.name)
