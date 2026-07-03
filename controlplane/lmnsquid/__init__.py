# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""linuxmuster-squid control plane package.

Manages Squid Docker containers (one per school x role) through the docker-py
SDK and exposes them via a FastAPI REST API.
"""
from __future__ import annotations

__version__ = "0.4.0"

__all__ = ["__version__"]
