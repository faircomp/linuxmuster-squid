# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pydantic models describing a managed Squid instance.

All externally-supplied string fields are strictly validated: they flow into
on-disk filenames, Docker container/volume names, bind-mount source paths and,
via envsubst, into the rendered squid.conf — so a lax field is a path-traversal
or injection sink. Fail closed at the API boundary.
"""

from __future__ import annotations

import ipaddress
import re

from pydantic import BaseModel, computed_field, field_validator

# school/role -> name -> filename + container/volume name: no '/', '..' (case allowed).
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,30}$")
# keytab_secret -> bind-mount source basename inside secrets_dir: no path separators.
_SECRET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
_GROUP_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$")
_REALM_RE = re.compile(r"^[A-Z0-9][A-Z0-9.-]{0,254}$")
_HOST_RE = re.compile(
    r"^(?=.{1,253}$)[a-zA-Z0-9]([a-zA-Z0-9-]{0,62})(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,62}))*$"
)
# image MUST carry an explicit :tag or @sha256:<digest> — never a bare repo
# (a bare repo makes docker-py pull EVERY tag = disk-exhaustion DoS).
_IMAGE_RE = re.compile(
    r"^[a-z0-9][a-z0-9._/:-]*(?::[A-Za-z0-9][A-Za-z0-9._-]{0,127}|@sha256:[a-f0-9]{64})$"
)


def _valid_cidr_list(value: str) -> bool:
    parts = value.split()
    if not parts:
        return False
    for part in parts:
        try:
            ipaddress.ip_network(part, strict=False)
        except ValueError:
            return False
    return True


class Instance(BaseModel):
    """A single Squid deployment, identified by ``school`` x ``role``."""

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
    log_retention_days: int = 30
    access_log_enabled: bool = True

    @field_validator("school", "role")
    @classmethod
    def _v_name(cls, v: str) -> str:
        if not _NAME_RE.match(v):
            raise ValueError("must match ^[A-Za-z0-9][A-Za-z0-9-]{0,30}$ (no '/', '..')")
        return v

    @field_validator("keytab_secret")
    @classmethod
    def _v_secret(cls, v: str) -> str:
        if ".." in v or not _SECRET_RE.match(v):
            raise ValueError("invalid keytab_secret (no path separators or '..')")
        return v

    @field_validator("ad_group")
    @classmethod
    def _v_group(cls, v: str) -> str:
        if not _GROUP_RE.match(v):
            raise ValueError("invalid ad_group")
        return v

    @field_validator("realm")
    @classmethod
    def _v_realm(cls, v: str) -> str:
        if not _REALM_RE.match(v):
            raise ValueError("realm must be UPPERCASE ^[A-Z0-9][A-Z0-9.-]+$")
        return v

    @field_validator("visible_hostname")
    @classmethod
    def _v_host(cls, v: str) -> str:
        if not _HOST_RE.match(v):
            raise ValueError("visible_hostname must be a valid FQDN")
        return v

    @field_validator("school_subnets")
    @classmethod
    def _v_subnets(cls, v: str) -> str:
        if not _valid_cidr_list(v):
            raise ValueError("school_subnets must be space-separated CIDR(s)")
        return v

    @field_validator("http_port")
    @classmethod
    def _v_port(cls, v: int) -> int:
        if not 1 <= v <= 65535:
            raise ValueError("http_port out of range")
        return v

    @field_validator("image")
    @classmethod
    def _v_image(cls, v: str) -> str:
        if not _IMAGE_RE.match(v):
            raise ValueError("image must carry an explicit :tag or @sha256:<digest> (no bare repo)")
        return v

    @field_validator("log_retention_days")
    @classmethod
    def _v_retention(cls, v: int) -> int:
        if not 1 <= v <= 3650:
            raise ValueError("log_retention_days must be between 1 and 3650")
        return v

    @computed_field  # type: ignore[prop-decorator]
    @property
    def name(self) -> str:
        """Logical instance name, e.g. ``demo-teachers``."""
        return f"{self.school}-{self.role}"

    @computed_field  # type: ignore[prop-decorator]
    @property
    def container_name(self) -> str:
        """Docker container name, e.g. ``lmnsquid-demo-teachers``."""
        return f"lmnsquid-{self.name}"


class InstancePatch(BaseModel):
    """Partial update for ``PATCH /v1/instances/{name}``.

    ``school`` and ``role`` are the instance identity and are intentionally NOT
    patchable (a rename would orphan the old container/file). Everything else may
    change; the API re-validates the merged result against :class:`Instance`.
    """

    ad_group: str | None = None
    realm: str | None = None
    visible_hostname: str | None = None
    http_port: int | None = None
    school_subnets: str | None = None
    keytab_secret: str | None = None
    cache_size_mb: int | None = None
    image: str | None = None
    log_retention_days: int | None = None
    access_log_enabled: bool | None = None


class UpdateRequest(BaseModel):
    """Body for ``POST /v1/instances/{name}/update``."""

    image: str

    @field_validator("image")
    @classmethod
    def _v_image(cls, v: str) -> str:
        if not _IMAGE_RE.match(v):
            raise ValueError("image must carry an explicit :tag or @sha256:<digest> (no bare repo)")
        return v
