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

    svc = DockerService(secrets_dir=str(secrets))
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
    docker = DockerService(secrets_dir=str(secrets))
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
