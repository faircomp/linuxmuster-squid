#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hydriert eine frisch geleaste crabbox-Box für den schweren Tier (Kerberos-E2E):
# Docker installieren, die E2E-Images vorziehen und das Data-Plane-Image bauen.
# Idempotent — mehrfach ausführbar. Docker wird via sudo angesprochen, falls der
# aktuelle User (noch) nicht auf den Socket darf.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "== crabbox bootstrap =="

# 1. Docker-Engine installieren (falls nötig)
if ! command -v docker >/dev/null 2>&1; then
  echo "-- installiere docker --"
  curl -fsSL https://get.docker.com | sh
fi
# aktuellen User in die docker-Gruppe (greift erst in Folge-Sessions) — best effort
sudo usermod -aG docker "$(id -un)" >/dev/null 2>&1 || true

# Docker-Aufruf wählen: direkt, sonst via sudo (frischer SSH-Login hat die Gruppe noch nicht)
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi
echo "-- docker via: $DOCKER --"
$DOCKER version >/dev/null

# 2. Images für den Kerberos-E2E vorziehen
$DOCKER pull ubuntu:24.04        || true
$DOCKER pull nowsci/samba-domain || true
$DOCKER pull nginx:alpine        || true

# 3. Data-Plane-Image bauen (validiert zugleich das Dockerfile / squid-openssl)
if [ -f image/templates/squid.conf.template ]; then
  echo "-- baue linuxmuster-squid:dev --"
  $DOCKER build -t linuxmuster-squid:dev image/
else
  echo "-- überspringe Image-Build: image/templates/squid.conf.template fehlt --"
fi

# 4. Python-Toolchain (venv) für die Control-Plane-Tests, falls Code vorhanden
if [ -f controlplane/pyproject.toml ]; then
  echo "-- Python-venv + Control-Plane-Deps --"
  sudo apt-get install -y -q python3-venv python3-pip >/dev/null 2>&1 || true
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip
  .venv/bin/pip install --quiet ruff mypy pytest pytest-asyncio httpx types-PyYAML
  .venv/bin/pip install --quiet -e ./controlplane
fi

echo "== bootstrap fertig =="
