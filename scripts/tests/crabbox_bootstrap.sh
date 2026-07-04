#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hydrates a freshly leased crabbox box for the heavy tier (Kerberos E2E):
# install Docker, pre-pull the E2E images and build the data-plane image.
# Idempotent — safe to run repeatedly. Docker is invoked via sudo if the
# current user is not (yet) allowed to access the socket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "== crabbox bootstrap =="

# 1. Install the Docker engine (if needed)
if ! command -v docker >/dev/null 2>&1; then
  echo "-- installing docker --"
  curl -fsSL https://get.docker.com | sh
fi
# add the current user to the docker group (only takes effect in later sessions) — best effort
sudo usermod -aG docker "$(id -un)" >/dev/null 2>&1 || true

# Choose the Docker invocation: directly, otherwise via sudo (a fresh SSH login does not have the group yet)
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi
echo "-- docker via: $DOCKER --"
$DOCKER version >/dev/null

# 2. Pre-pull the images for the Kerberos E2E
$DOCKER pull ubuntu:24.04        || true
$DOCKER pull nowsci/samba-domain || true
$DOCKER pull nginx:alpine        || true

# 3. Build the data-plane image (also validates the Dockerfile / squid-openssl)
if [ -f image/templates/squid.conf.template ]; then
  echo "-- building linuxmuster-squid:dev --"
  $DOCKER build -t linuxmuster-squid:dev image/
else
  echo "-- skipping image build: image/templates/squid.conf.template missing --"
fi

# 4. Python toolchain (venv) for the control-plane tests, if code is present
if [ -f controlplane/pyproject.toml ]; then
  echo "-- Python venv + control-plane deps --"
  sudo apt-get install -y -q python3-venv python3-pip >/dev/null 2>&1 || true
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet ruff mypy pytest pytest-asyncio httpx types-PyYAML
  .venv/bin/pip install --quiet -e ./controlplane
fi

echo "== bootstrap done =="
