# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Git-backed YAML store for :class:`~lmnsquid.models.Instance` objects."""

from __future__ import annotations

import logging
import subprocess
from collections.abc import Sequence
from pathlib import Path

import yaml

from .models import Instance

logger = logging.getLogger("lmnsquid.store")

# Author of the change-log commits. Passed on every git call so the commit works even
# when the repository carries no user.name/user.email (restored from a backup, created
# by hand); the postinst sets the same identity locally for commits made by an admin.
_GIT_AUTHOR = ("linuxmuster-squid", "lmnsquid@localhost")


class Store:
    """Persist instances as ``<name>.yaml`` files, git-committed as the change log.

    A git failure never fails the API call (the container lifecycle must not depend
    on it), but it is logged at ERROR: the change log is a documented feature and
    silently missing commits are exactly the bug this store had until 7.3.1.
    """

    def __init__(self, path: str) -> None:
        self.path = Path(path)
        self.path.mkdir(parents=True, exist_ok=True)
        self._warned_no_repo = False

    def _file(self, name: str) -> Path:
        if not name or "/" in name or "\\" in name or ".." in name:
            raise ValueError(f"unsafe instance name: {name!r}")
        return self.path / f"{name}.yaml"

    def list(self) -> list[Instance]:
        """Return all stored instances, sorted by name."""
        instances: list[Instance] = []
        for file in sorted(self.path.glob("*.yaml")):
            try:
                data = yaml.safe_load(file.read_text(encoding="utf-8"))
            except (OSError, yaml.YAMLError):
                logger.warning("failed to read instance file %s", file.name)
                continue
            if not isinstance(data, dict):
                continue
            try:
                instances.append(Instance(**data))
            except Exception:  # noqa: BLE001 - skip invalid records, keep listing
                logger.warning("invalid instance record in %s", file.name)
        return instances

    def get(self, name: str) -> Instance | None:
        """Return the instance named ``name`` or ``None`` if absent."""
        file = self._file(name)
        if not file.is_file():
            return None
        try:
            data = yaml.safe_load(file.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError):
            logger.warning("failed to read instance file %s", file.name)
            return None
        if not isinstance(data, dict):
            return None
        return Instance(**data)

    def put(self, inst: Instance) -> None:
        """Write ``inst`` to disk and, if inside a git repo, commit it."""
        file = self._file(inst.name)
        payload = inst.model_dump(exclude={"name", "container_name"})
        file.write_text(
            yaml.safe_dump(payload, default_flow_style=False, sort_keys=True),
            encoding="utf-8",
        )
        if self._git(["add", "--", file.name], f"add {file.name}"):
            self._commit_if_staged(file.name, f"lmnsquid: update {inst.name}")

    def delete(self, name: str) -> None:
        """Remove the instance file (+ the updater's ``.prev`` note) and commit the removal."""
        file = self._file(name)
        # The rollback reference written by the updater has no meaning without the instance.
        (self.path / f"{name}.prev").unlink(missing_ok=True)
        if not file.exists():
            return
        file.unlink()
        if self._git(["rm", "-q", "--ignore-unmatch", "--", file.name], f"rm {file.name}"):
            self._commit_if_staged(file.name, f"lmnsquid: remove {name}")

    def _commit_if_staged(self, filename: str, message: str) -> None:
        # An edit that changed nothing stages nothing; do not log a spurious
        # "nothing to commit" error for it.
        probe = self._run(["diff", "--cached", "--quiet", "--", filename])
        if probe is not None and probe.returncode == 0:
            return
        self._git(["commit", "-q", "-m", message, "--", filename], f"commit {filename}")

    def _run(self, args: Sequence[str]) -> subprocess.CompletedProcess[str] | None:
        """Run git in the repo with the fixed author identity; ``None`` if git cannot run."""
        name, email = _GIT_AUTHOR
        try:
            return subprocess.run(
                ["git", "-c", f"user.name={name}", "-c", f"user.email={email}", *args],
                cwd=self.path,
                capture_output=True,
                text=True,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            logger.error("git %s in %s failed to run: %s", args[0], self.path, exc)
            return None

    def _git(self, args: Sequence[str], what: str) -> bool:
        """Run a git command; log (never raise) on failure, return success."""
        if not (self.path / ".git").exists():
            if not self._warned_no_repo:
                logger.warning(
                    "%s is not a git repository; instance changes are not recorded", self.path
                )
                self._warned_no_repo = True
            return False
        result = self._run(args)
        if result is None:
            return False
        if result.returncode != 0:
            logger.error(
                "git %s in %s exited %d: %s",
                what,
                self.path,
                result.returncode,
                result.stderr.strip(),
            )
            return False
        return True
