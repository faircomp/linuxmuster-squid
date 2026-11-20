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
from typing import Any

import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("LMNSQUID_DOCKER_IT") != "1",
    reason="set LMNSQUID_DOCKER_IT=1 (needs Docker + linuxmuster-squid:dev image)",
)

IMAGE = os.environ.get("LMNSQUID_IT_IMAGE", "linuxmuster-squid:dev")
# The data-plane image 7.3.7 pins, the last one without ADR-016: a constant, not DEFAULT_IMAGE,
# which moves to an image that reads the noauth list before 7.3.8 is tagged.
OLD_IMAGE = os.environ.get(
    "LMNSQUID_IT_OLD_IMAGE",
    "ghcr.io/faircomp/linuxmuster-squid"
    "@sha256:d13625b51a99d62f14c37d18453092bbde651cb34df080dd49f3937f7f5f46ef",
)


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
        assert svc.reload(inst.name) == {"name": inst.name, "reloaded": True, "notices": []}

        # Hand-edited lists that squid 6 refuses as such (a covered name before its parent,
        # the bare apex): lists-sync.sh drops those entries on reload and at the next start.
        (lists / inst.name / "blocked.domains").write_text(
            ".a.example.org\nexample.org\n.example.org\n"
        )
        (lists / inst.name / "noauth.domains").write_text(
            ".graph.microsoft.com\n.microsoft.com\nmicrosoft.com\n"
        )
        reloaded = svc.reload(inst.name)
        assert reloaded["reloaded"] is True
        # what was ignored is in the response and in the container log (`lmnsquid logs`)
        assert any("already covered" in n for n in reloaded["notices"]), reloaded
        time.sleep(2)
        assert "blocked.domains: 2 entries ignored, already covered" in svc.logs(inst.name, tail=50)
        svc.restart(inst.name)
        deadline = time.monotonic() + 60
        health = None
        while time.monotonic() < deadline:
            health = svc.status(inst.name)["health"]
            if health in ("healthy", "unhealthy"):
                break
            time.sleep(2)
        assert svc.status(inst.name)["running"] is True and health == "healthy"

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


def test_real_old_image_ignores_the_noauth_list(tmp_path: Path) -> None:
    """An image from before ADR-016 (what installed instances run until the upgrade replaces
    their containers) next to a list directory with noauth.domains: it starts healthy, and the
    noauth reload is refused instead of reporting a reload that changes nothing."""
    from lmnsquid.docker_service import DockerService
    from lmnsquid.models import Instance

    old_image = OLD_IMAGE
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


# -- log rotation in the hardened container (cap_drop ALL, read-only, no-new-privileges) --------
# The containers come from the real DockerService, so they carry exactly the control plane's
# security options and the per-instance log volume.

LOGDIR = "/var/log/squid"
LOGROTATE = f"logrotate -f -s {LOGDIR}/.logrotate.state /run/lmnsquid/logrotate.conf"


def _hardened(tmp_path: Path, school: str, port: int, retention: int = 2) -> tuple[Any, Any]:
    from lmnsquid.docker_service import DockerService
    from lmnsquid.models import Instance

    secrets = tmp_path / "secrets"
    secrets.mkdir()
    (secrets / "it.keytab").write_bytes(b"dummy-keytab-not-valid")
    svc = DockerService(secrets_dir=str(secrets), blocklists_dir=str(tmp_path / "lists"))
    inst = Instance(
        school=school,
        role="teachers",
        ad_group="teachers",
        realm="EXAMPLE.INTERNAL",
        visible_hostname=f"squid-{school}.example.internal",
        http_port=port,
        school_subnets="0.0.0.0/0",
        keytab_secret="it.keytab",
        cache_size_mb=100,
        log_retention_days=retention,
        image=IMAGE,
    )
    svc.remove(inst.name)  # clean slate, log volume included
    return svc, inst


def _sh(svc: Any, inst: Any, cmd: str) -> tuple[int, bytes]:
    """Run ``cmd`` in the instance container as its root (same capabilities as the entrypoint)."""
    code, out = svc._get(inst.name).exec_run(["sh", "-c", cmd])
    return int(code), bytes(out)


def _out(svc: Any, inst: Any, cmd: str) -> str:
    code, out = _sh(svc, inst, cmd)
    assert code == 0, (cmd, out)
    return out.decode()


def _request(svc: Any, inst: Any, url: str) -> None:
    before = _out(svc, inst, f"cat {LOGDIR}/access.log | wc -l")
    _sh(svc, inst, f"squidclient -h 127.0.0.1 -p {inst.http_port} {url}")
    deadline = time.monotonic() + 15
    while _out(svc, inst, f"cat {LOGDIR}/access.log | wc -l") == before:
        assert time.monotonic() < deadline, f"no access-log line for {url}"
        time.sleep(0.5)


def _rotate(svc: Any, inst: Any) -> None:
    code, out = _sh(svc, inst, LOGROTATE + " 2>&1")
    assert code == 0 and b"error" not in out, out.decode()


def _files(svc: Any, inst: Any) -> dict[str, str]:
    """``name -> "<mode> <owner>:<group> <size>"`` of every file in the log directory."""
    listing = _out(svc, inst, f"cd {LOGDIR} && stat -c '%n %a %U:%G %s' * .logrotate.state")
    return {line.split(" ", 1)[0]: line.split(" ", 1)[1] for line in listing.splitlines()}


def _fill_volume(svc: Any, inst: Any, script: str) -> str:
    """Prepare the instance's log volume before its container exists (an upgraded host)."""
    volume = f"lmnsquid-logs-{inst.name}"
    svc.client.volumes.create(volume)
    out = svc.client.containers.run(
        IMAGE,
        entrypoint=["sh", "-c", "set -eu; cd " + LOGDIR + "; " + script],
        volumes={volume: {"bind": LOGDIR, "mode": "rw"}},
        remove=True,
    )
    return bytes(out).decode()


# The state of a volume that images up to 7.3.9 rotated for a while: every run left an empty 0600
# copy, the next ones renamed it to *.backup, the logs themselves kept growing.
_BACKLOG = (
    "seq 1 20000 | awk '{printf \"%d.000 1 10.0.0.1 TCP_DENIED/407 3900 GET "
    "http://old-%d.invalid/ - HIER_NONE/- text/html\\n\", 1700000000+$1, $1}' > access.log; "
    "echo 'old cache line' > cache.log; "
    "for f in access.log.1 access.log.1.gz access.log.1.gz-2026111803.backup "
    "access.log.1.gz-2026111903.backup cache.log.1 cache.log.1-2026111803.backup; do "
    ": > $f; chmod 600 $f; done; "
    "echo 'not empty' > access.log.1.gz-2026111703.backup; : > unrelated-empty.txt; "
    "chown proxy:proxy *; chmod 640 access.log cache.log; "
    # last rotation attempt yesterday, so the entrypoint's first run is due for access.log
    "y=$(date -d yesterday +%Y-%-m-%-d); printf 'logrotate state -- version 2\\n"
    '"/var/log/squid/access.log" %s-3:0:0\\n"/var/log/squid/cache.log" %s-3:0:0\\n\' '
    '"$y" "$y" > .logrotate.state; chmod 640 .logrotate.state; '
)
_LEFTOVERS = [
    "access.log.1.gz",
    "access.log.1.gz-2026111803.backup",
    "access.log.1.gz-2026111903.backup",
    "cache.log.1",
    "cache.log.1-2026111803.backup",
]


def test_log_rotation_hardened(tmp_path: Path) -> None:
    """copytruncate works under the control plane's capabilities: content in .1, the log
    emptied and written on, modes kept, retention honoured (access.log and cache.log)."""
    svc, inst = _hardened(tmp_path, "itl", 3196, retention=2)
    try:
        svc.ensure_running(inst)
        for i in range(3):
            _request(svc, inst, f"http://before-{i}.invalid/")
        access = _out(svc, inst, f"cat {LOGDIR}/access.log")
        cache = _out(svc, inst, f"cat {LOGDIR}/cache.log")
        assert all(f"before-{i}.invalid" in access for i in range(3)) and cache

        _rotate(svc, inst)
        files = _files(svc, inst)
        # (the image's healthcheck may add a line at any time, hence prefix, not equality)
        assert _out(svc, inst, f"cat {LOGDIR}/access.log.1").startswith(access)
        assert "before-" not in _out(svc, inst, f"cat {LOGDIR}/access.log")
        assert files["access.log"].startswith("640 proxy:proxy ")
        assert files["access.log.1"].startswith("640 proxy:proxy ")
        assert _out(svc, inst, f"zcat {LOGDIR}/cache.log.1.gz").startswith(cache)
        assert files["cache.log.1.gz"].startswith("640 proxy:proxy ")
        assert files["cache.log"].startswith("640 proxy:proxy ")

        # squid writes on into the truncated log (no hole of NULs), the tailer follows it
        _request(svc, inst, "http://after-rotation.invalid/")
        code, raw = _sh(svc, inst, f"cat {LOGDIR}/access.log")
        assert code == 0 and b"\0" not in raw and b"before-" not in raw
        assert b"after-rotation.invalid" in raw
        time.sleep(2)
        assert "after-rotation.invalid" in svc.logs(inst.name, tail=20)

        # retention: rotate 2 (access.log) and rotate 4 (cache.log), the older ones go
        for i in range(5):
            _request(svc, inst, f"http://day-{i}.invalid/")
            _sh(svc, inst, f"echo 'cache line {i}' >> {LOGDIR}/cache.log")
            _rotate(svc, inst)
        files = _files(svc, inst)
        assert sorted(files) == [
            ".logrotate.state",
            "access.log",
            "access.log.1",
            "access.log.2.gz",
            "cache.log",
            "cache.log.1.gz",
            "cache.log.2.gz",
            "cache.log.3.gz",
            "cache.log.4.gz",
        ], files
        for name, stat in files.items():
            if name != ".logrotate.state":
                assert stat.startswith("640 proxy:proxy "), (name, stat)
        assert "day-4.invalid" in _out(svc, inst, f"cat {LOGDIR}/access.log.1")
        assert "day-3.invalid" in _out(svc, inst, f"zcat {LOGDIR}/access.log.2.gz")
        assert "logrotate failed" not in svc.logs(inst.name, tail=200)
    finally:
        svc.remove(inst.name)


def test_log_rotation_after_upgrade(tmp_path: Path) -> None:
    """A volume from the broken rotation: the empty leftovers go (nothing with content), the
    backlog is rotated by the first scheduled run and compressed by the next one."""
    svc, inst = _hardened(tmp_path, "itu", 3195, retention=30)
    try:
        backlog_sha = _fill_volume(svc, inst, _BACKLOG + "sha256sum access.log").split()[0]
        svc.ensure_running(inst)
        deadline = time.monotonic() + 30
        while "access.log.1" not in _files(svc, inst):
            assert time.monotonic() < deadline, _files(svc, inst)
            time.sleep(1)

        files = _files(svc, inst)
        for name in _LEFTOVERS:
            assert name not in files, (name, files)
        assert _out(svc, inst, f"cat {LOGDIR}/access.log.1.gz-2026111703.backup") == "not empty\n"
        assert "unrelated-empty.txt" in files
        log = svc.logs(inst.name, tail=200)
        assert "removed 6 empty file(s) left by failed log rotations" in log
        assert "logrotate failed" not in log

        # the not forced first run rotated the backlog completely into .1, with the log's mode
        assert _out(svc, inst, f"sha256sum < {LOGDIR}/access.log.1").split()[0] == backlog_sha
        assert files["access.log.1"].startswith("640 proxy:proxy ")
        assert files["access.log"].startswith("640 proxy:proxy ")
        assert "old-" not in _out(svc, inst, f"cat {LOGDIR}/access.log")
        # cache.log is weekly: not due yet, left alone
        assert files["cache.log"].startswith("640 proxy:proxy ") and "cache.log.1" not in files

        # the next day the backlog is compressed (delaycompress) and still complete
        _request(svc, inst, "http://next-day.invalid/")
        _rotate(svc, inst)
        sha = _out(svc, inst, f"zcat {LOGDIR}/access.log.2.gz | sha256sum").split()[0]
        assert sha == backlog_sha
        assert _files(svc, inst)["access.log.2.gz"].startswith("640 proxy:proxy ")
    finally:
        svc.remove(inst.name)


def test_log_rotation_error_reported(tmp_path: Path) -> None:
    """A failing rotation is no longer silent: one line in the container log per run."""
    svc, inst = _hardened(tmp_path, "ite", 3194)
    try:
        # a rotated file proxy cannot read: compressing it as the log's owner must fail
        _fill_volume(
            svc,
            inst,
            _BACKLOG + "rm -f access.log.1; echo secret > access.log.1; chmod 600 access.log.1; "
            "chmod 644 .logrotate.state",  # a warning first: the error line must still win
        )
        svc.ensure_running(inst)
        deadline = time.monotonic() + 30
        while "logrotate failed" not in svc.logs(inst.name, tail=200):
            assert time.monotonic() < deadline, svc.logs(inst.name, tail=200)
            time.sleep(1)
        failed = [ln for ln in svc.logs(inst.name, tail=200).splitlines() if "logrotate" in ln]
        assert len(failed) == 1, failed
        assert failed[0].startswith(
            "linuxmuster-squid: logrotate failed (1 error(s)), first: error:"
        )
    finally:
        svc.remove(inst.name)
