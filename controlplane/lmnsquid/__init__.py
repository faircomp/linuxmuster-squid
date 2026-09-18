# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""linuxmuster-squid control plane package.

Manages Squid Docker containers (one per school x role) through the docker-py
SDK and exposes them via a FastAPI REST API.

The version is not spelled out here: ``importlib.metadata.version("lmnsquid")``
returns the one debian/changelog defines (fed in by setup.py at build time).
"""
