# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for :mod:`lmnsquid.models` derived properties and defaults."""

from __future__ import annotations

from lmnsquid.models import Instance, InstancePatch


def test_name_is_school_dash_role(instance: Instance) -> None:
    assert instance.name == "default-school-teachers"


def test_container_name_is_prefixed(instance: Instance) -> None:
    assert instance.container_name == "lmnsquid-default-school-teachers"


def test_container_name_tracks_name() -> None:
    inst = Instance(
        school="schuleB",
        role="students",
        ad_group="students",
        realm="EXAMPLE.LAN",
        visible_hostname="proxy-b.example.lan",
        keytab_secret="schuleB-students.keytab",
        image="ghcr.io/example/lmnsquid:latest",
    )
    assert inst.name == "schuleB-students"
    assert inst.container_name == "lmnsquid-schuleB-students"


def test_defaults_applied() -> None:
    inst = Instance(
        school="s",
        role="r",
        ad_group="g",
        realm="EXAMPLE.LAN",
        visible_hostname="h",
        keytab_secret="s-r.keytab",
        image="img",
    )
    assert inst.http_port == 3128
    assert inst.school_subnets == "0.0.0.0/0"
    assert inst.cache_size_mb == 1000


def test_patch_all_fields_optional() -> None:
    patch = InstancePatch()
    dumped = patch.model_dump(exclude_unset=True)
    assert dumped == {}


def test_patch_partial() -> None:
    patch = InstancePatch(cache_size_mb=2000)
    dumped = patch.model_dump(exclude_unset=True)
    assert dumped == {"cache_size_mb": 2000}
