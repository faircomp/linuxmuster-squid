# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pydantic models describing a managed Squid instance."""
from __future__ import annotations

from pydantic import BaseModel, computed_field


class Instance(BaseModel):
    """A single Squid deployment, identified by ``school`` x ``role``.

    Every field maps to configuration consumed (directly or indirectly) by the
    container's ``entrypoint.sh`` via environment variables.
    """

    school: str
    role: str
    ad_group: str
    realm: str
    visible_hostname: str
    http_port: int = 3128
    school_subnets: str = "0.0.0.0/0"
    keytab_secret: str
    cache_size_mb: int = 1000
    image: str

    @computed_field  # type: ignore[prop-decorator]
    @property
    def name(self) -> str:
        """Logical instance name, e.g. ``demo-teacher``."""
        return f"{self.school}-{self.role}"

    @computed_field  # type: ignore[prop-decorator]
    @property
    def container_name(self) -> str:
        """Docker container name, e.g. ``lmnsquid-demo-teacher``."""
        return f"lmnsquid-{self.name}"


class InstancePatch(BaseModel):
    """Partial update payload for ``PATCH /v1/instances/{name}``.

    Every field mirrors :class:`Instance` but is optional so that callers can
    send only the values they wish to change.
    """

    school: str | None = None
    role: str | None = None
    ad_group: str | None = None
    realm: str | None = None
    visible_hostname: str | None = None
    http_port: int | None = None
    school_subnets: str | None = None
    keytab_secret: str | None = None
    cache_size_mb: int | None = None
    image: str | None = None
