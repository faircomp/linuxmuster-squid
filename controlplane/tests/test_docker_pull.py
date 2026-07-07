# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""_pull() must parse ``@sha256`` digests and ``:tag`` refs correctly (no real Docker)."""

from __future__ import annotations

from unittest.mock import MagicMock

from lmnsquid.docker_service import DockerService


def _service_with_mock_client() -> DockerService:
    ds = DockerService.__new__(DockerService)  # bypass __init__ (no docker daemon)
    ds.client = MagicMock()
    return ds


def test_pull_keeps_sha256_digest_intact() -> None:
    ds = _service_with_mock_client()
    digest = "sha256:" + "a" * 64
    ds._pull(f"ghcr.io/faircomp/linuxmuster-squid@{digest}")
    # the whole 'sha256:<hex>' must survive as the tag (not truncated to '<hex>')
    ds.client.images.pull.assert_called_once_with(
        "ghcr.io/faircomp/linuxmuster-squid", tag=digest
    )


def test_pull_handles_plain_tag() -> None:
    ds = _service_with_mock_client()
    ds._pull("ghcr.io/x/y:v2")
    ds.client.images.pull.assert_called_once_with("ghcr.io/x/y", tag="v2")


def test_pull_does_not_mistake_registry_port_for_tag() -> None:
    ds = _service_with_mock_client()
    ds._pull("registry.local:5000/proxy:v1")
    ds.client.images.pull.assert_called_once_with("registry.local:5000/proxy", tag="v1")
