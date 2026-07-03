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
