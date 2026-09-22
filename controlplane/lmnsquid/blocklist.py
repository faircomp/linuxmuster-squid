# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Per-instance domain blocklist: a file on the host, mounted read-only into the container.

Every instance owns ``<blocklists_dir>/<name>/blocked.domains``. The DIRECTORY is
bind-mounted read-only at ``/etc/squid/lists`` -- the path the rendered ``squid.conf``
already reads its ``dstdomain`` / ``ssl::server_name`` ACL from -- so the image needs no
change and the read-only rootfs stays read-only. The directory rather than the file is
mounted on purpose: a single-file bind mount pins the inode, so an atomic replace on the
host (an editor, ``blocklist-refresh.sh``, this module) would never reach the container.
"""

from __future__ import annotations

import os
import re
import shutil
import tempfile
from pathlib import Path

FILE_NAME = "blocked.domains"
CONTAINER_DIR = "/etc/squid/lists"  # squid.conf: acl blocked_domains dstdomain "/etc/squid/lists/blocked.domains"
# Instance name = <school>-<role> (models._NAME_RE per part): the directory name under root.
_INSTANCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{1,62}$")

# One DNS name (labels of letters/digits/hyphens), after IDNA encoding and lower-casing.
_LABEL = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
_DOMAIN_RE = re.compile(rf"^{_LABEL}(?:\.{_LABEL})*$")


def normalize_domain(value: str) -> str:
    """Return ``value`` as the list entry ``.example.org`` or raise ``ValueError``.

    Lower-cased, IDNA-encoded (``müller.de`` -> ``xn--mller-kva.de``) and with a leading
    dot forced: for squid's ``dstdomain``/``ssl::server_name`` the dot means "this domain
    and every subdomain", which is what "block example.org" means to an admin.
    """
    raw = value.strip().lower().strip(".")
    if not raw:
        raise ValueError("domain must not be empty")
    try:
        name = raw.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise ValueError(f"invalid domain {value!r}") from exc
    if len(name) > 253 or not _DOMAIN_RE.match(name):
        raise ValueError(f"invalid domain {value!r}")
    return f".{name}"


class Blocklist:
    """Read and modify the ``blocked.domains`` files under ``root`` (one dir per instance)."""

    def __init__(self, root: str) -> None:
        self.root = Path(root)

    def dir_for(self, name: str) -> Path:
        """Host directory mounted into the instance ``name`` (rejects anything but a name)."""
        if not _INSTANCE_RE.match(name):
            raise ValueError(f"unsafe instance name: {name!r}")
        return self.root / name

    def file_for(self, name: str) -> Path:
        return self.dir_for(name) / FILE_NAME

    def ensure(self, name: str) -> Path:
        """Create the directory and an empty list if absent; return the directory.

        Modes are explicit: squid reads the file as ``proxy`` inside the container
        (0644 / 0755), the control plane writes it on the host.
        """
        directory = self.dir_for(name)
        directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        file = directory / FILE_NAME
        if not file.exists():
            self._write(file, [])
        return directory

    def read(self, name: str) -> list[str]:
        """Return the entries squid sees (comments and blank lines skipped)."""
        file = self.file_for(name)
        if not file.is_file():
            return []
        entries: list[str] = []
        for raw in file.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line and not line.startswith("#"):
                entries.append(line)
        return entries

    def add(self, name: str, domain: str) -> list[str]:
        """Add ``domain`` (idempotent); return the new list."""
        entry = normalize_domain(domain)
        self.ensure(name)
        entries = sorted(set(self.read(name)) | {entry})
        self._write(self.file_for(name), entries)
        return entries

    def remove(self, name: str, domain: str) -> list[str]:
        """Remove ``domain`` (with or without the leading dot); ``KeyError`` if absent."""
        entry = normalize_domain(domain)
        current = self.read(name)
        # A hand-edited file may carry the bare form; both mean the same target.
        remaining = [e for e in current if e not in (entry, entry[1:])]
        if len(remaining) == len(current):
            raise KeyError(entry)
        self._write(self.file_for(name), remaining)
        return remaining

    def delete(self, name: str) -> None:
        """Remove the instance's directory (called when the instance is removed)."""
        directory = self.dir_for(name)
        if directory.is_dir():
            shutil.rmtree(directory)

    @staticmethod
    def _write(file: Path, entries: list[str]) -> None:
        # Atomic replace inside the directory: squid (on reload) or an editor never sees a
        # half-written list, and a root-owned file left behind by blocklist-refresh.sh
        # does not block the control plane (only the directory must be writable).
        fd, tmp = tempfile.mkstemp(dir=file.parent, prefix=f".{FILE_NAME}.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write("".join(f"{entry}\n" for entry in entries))
            os.chmod(tmp, 0o644)
            os.replace(tmp, file)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
