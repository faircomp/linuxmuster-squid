# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
"""Console entrypoint that assembles and serves the control plane API."""

from __future__ import annotations

import logging

import uvicorn

from .api import create_app
from .config import load_settings
from .docker_service import DockerService
from .reconciler import Reconciler
from .store import Store
from .updater import Updater


def main() -> None:
    """Load settings, wire the components together and run the uvicorn server."""
    logging.basicConfig(level=logging.INFO)
    settings = load_settings()
    store = Store(settings.instances_dir)
    docker = DockerService(
        settings.docker_host, settings.secrets_dir, settings.container_bind_ip
    )
    reconciler = Reconciler(store, docker)
    updater = Updater(store, docker, reconciler)
    app = create_app(settings, store, reconciler, docker, updater)
    uvicorn.run(app, host=settings.bind_host, port=settings.bind_port)


if __name__ == "__main__":
    main()
