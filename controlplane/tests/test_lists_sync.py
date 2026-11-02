# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""image/lists-sync.sh as it is (sh + awk + sort), next to the Python rules it must match.

The control plane refuses a noauth entry with :func:`normalize_noauth_domain`; the container
ignores a hand-written one with lists-sync.sh. Both must agree, so every case here goes
through both.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from lmnsquid.blocklist import normalize_noauth_domain, uncovered

SCRIPT = Path(__file__).resolve().parents[2] / "image" / "lists-sync.sh"

pytestmark = pytest.mark.skipif(
    not all(shutil.which(tool) for tool in ("sh", "awk", "sort", "sed")),
    reason="needs sh, awk, sort and sed",
)


def _sync(tmp_path: Path, blocked: bytes = b"", noauth: bytes | None = None) -> tuple[Path, str]:
    src, dst = tmp_path / "src", tmp_path / "dst"
    src.mkdir(exist_ok=True)
    (src / "blocked.domains").write_bytes(blocked)
    if noauth is not None:
        (src / "noauth.domains").write_bytes(noauth)
    env = {**os.environ, "LISTS_SYNC_SRC": str(src), "LISTS_SYNC_DST": str(dst)}
    done = subprocess.run(
        ["sh", str(SCRIPT)], env=env, capture_output=True, text=True, check=True, timeout=60
    )
    return dst, done.stderr


def _python_accepts(name: str) -> bool:
    try:
        normalize_noauth_domain(name)
    except ValueError:
        return False
    return True


@pytest.mark.parametrize(
    "name",
    [
        # IPv4 in inet_aton notations: dotted, short, decimal, octal, hex, mixed
        "172.28.0.20",
        "127.1",
        "2887516181",
        "0177.0.0.1",
        "0x7f000001",
        "0x7f.0x1",
        "1.2.3.0x4",
        "0x0a.0x00.0x00.0x01",
        "0xac.0x1c.0x0.0x15",
        "172.28.0.0x15",
        # single labels, IPv6, not a name
        "com",
        ".com",
        "localhost",
        "::1",
        "fe80::1",
        "*.example.org",
        "x_y.example.org",
        # names that must pass: hex-looking or numeric labels next to a real label
        "office.com",
        ".sharepoint.com",
        "0xcafe.com",
        "1und1.de",
        "10.0.0.example",
        "x.co.uk",
        "xn--bcher-kva.de",
    ],
)
def test_python_and_lists_sync_agree(tmp_path: Path, name: str) -> None:
    dst, stderr = _sync(tmp_path, noauth=f"{name}\n".encode())
    kept = (dst / "noauth.domains").read_text().split()
    assert bool(kept) is _python_accepts(name), (name, kept, stderr)
    if not kept:
        assert f"ignored, not a domain name: {name.lower()}" in stderr


def test_covered_entries_like_python(tmp_path: Path) -> None:
    raw = [".a.example.org", "example.org", ".example.org", "B.Example.Org.", ".other.org"]
    dst, stderr = _sync(tmp_path, blocked="\n".join(raw).encode() + b"\n")
    assert sorted((dst / "blocked.domains").read_text().split()) == uncovered(raw)
    assert "already covered by a listed parent domain" in stderr


def test_missing_noauth_file_is_an_empty_list(tmp_path: Path) -> None:
    dst, stderr = _sync(tmp_path, blocked=b".example.org\n")
    assert (dst / "noauth.domains").read_text() == ""
    assert "domains without proxy auth: none" in stderr
