# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""The git change log of the instance store: commits on put/update/delete, loud on failure."""

from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path

import pytest

from lmnsquid.models import Instance
from lmnsquid.store import Store

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git not installed")


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=True
    ).stdout


def _log(repo: Path) -> list[str]:
    out = subprocess.run(
        ["git", "log", "--format=%s"], cwd=repo, capture_output=True, text=True, check=False
    ).stdout
    return out.splitlines()


def _inst(cache: int = 1000) -> Instance:
    return Instance(
        school="s",
        role="teachers",
        ad_group="teachers",
        realm="EXAMPLE.LAN",
        visible_hostname="proxy.example.lan",
        keytab_secret="proxy.keytab",
        image="ghcr.io/x/y:1",
        cache_size_mb=cache,
    )


@pytest.fixture
def repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    # No user/system git config: like the lmnsquid service account, whose repo the
    # postinst configures -- the store must commit even without a configured identity.
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", "/dev/null")
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", "/dev/null")
    path = tmp_path / "instances"
    path.mkdir()
    _git(path, "init", "-q")
    return path


def test_put_update_delete_are_committed(repo: Path, caplog: pytest.LogCaptureFixture) -> None:
    store = Store(str(repo))
    with caplog.at_level(logging.WARNING, logger="lmnsquid.store"):
        store.put(_inst())
        store.put(_inst(cache=2000))
        store.put(_inst(cache=2000))  # no change -> no empty commit, no error
        (repo / "s-teachers.prev").write_text("ghcr.io/x/y:0")
        store.delete("s-teachers")

    assert _log(repo) == [
        "lmnsquid: remove s-teachers",
        "lmnsquid: update s-teachers",
        "lmnsquid: update s-teachers",
    ]
    assert not caplog.records, [r.getMessage() for r in caplog.records]
    assert _git(repo, "status", "--porcelain") == ""  # nothing left staged/untracked
    assert not (repo / "s-teachers.prev").exists()
    assert "linuxmuster-squid <lmnsquid@localhost>" in _git(repo, "log", "-1", "--format=%an <%ae>")


def test_not_a_repo_warns_once_but_stores(tmp_path: Path, caplog: pytest.LogCaptureFixture) -> None:
    store = Store(str(tmp_path / "plain"))
    with caplog.at_level(logging.WARNING, logger="lmnsquid.store"):
        store.put(_inst())
        store.put(_inst(cache=2000))
    assert store.get("s-teachers") is not None
    warnings = [r for r in caplog.records if "not a git repository" in r.getMessage()]
    assert len(warnings) == 1


def test_git_failure_is_logged_as_error(repo: Path, caplog: pytest.LogCaptureFixture) -> None:
    # A repository that cannot be written to (e.g. wrong ownership in production) must
    # surface in the journal instead of vanishing at debug level.
    (repo / ".git" / "objects").chmod(0o500)
    try:
        store = Store(str(repo))
        with caplog.at_level(logging.ERROR, logger="lmnsquid.store"):
            store.put(_inst())
    finally:
        (repo / ".git" / "objects").chmod(0o755)
    assert store.get("s-teachers") is not None  # the yaml is written regardless
    assert any(r.levelno == logging.ERROR and "git" in r.getMessage() for r in caplog.records)
