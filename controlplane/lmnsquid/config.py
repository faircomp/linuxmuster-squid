# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Runtime settings for the control plane.

Settings come from an optional YAML file, overlaid by ``LMNSQUID_*``
environment variables (environment always wins over the file).
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml
from pydantic_settings import BaseSettings, SettingsConfigDict

_ENV_PREFIX = "LMNSQUID_"


class Settings(BaseSettings):
    """Control-plane configuration."""

    api_token: str
    instances_dir: str = "/etc/linuxmuster-squid/instances"
    secrets_dir: str = "/etc/linuxmuster-squid/secrets"
    docker_host: str | None = None
    bind_host: str = "127.0.0.1"
    bind_port: int = 8080
    api_url: str = "http://127.0.0.1:8080"
    version: str = "0.4.0"

    model_config = SettingsConfigDict(env_prefix=_ENV_PREFIX)


def load_settings(config_path: str | None = None) -> Settings:
    """Load :class:`Settings` from an optional YAML file plus environment.

    Values read from ``config_path`` act as defaults; any matching
    ``LMNSQUID_<FIELD>`` environment variable takes precedence.
    """
    if config_path is None:
        config_path = os.environ.get("LMNSQUID_CONFIG", "/etc/linuxmuster-squid/config.yml")
    overrides: dict[str, Any] = {}
    if config_path:
        path = Path(config_path)
        if path.is_file():
            data = yaml.safe_load(path.read_text()) or {}
            if isinstance(data, dict):
                for key, value in data.items():
                    field = str(key)
                    env_name = f"{_ENV_PREFIX}{field.upper()}"
                    # Let the environment override the file.
                    if env_name in os.environ:
                        continue
                    overrides[field] = value
    return Settings(**overrides)
