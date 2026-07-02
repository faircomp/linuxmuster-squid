#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Hydriert eine frisch geleaste crabbox-Box für den schweren Tier (Kerberos-E2E):
# Docker installieren, die E2E-Images vorziehen und das Data-Plane-Image bauen.
# Idempotent — mehrfach ausführbar.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "== crabbox bootstrap =="

# 1. Docker-Engine
if ! command -v docker >/dev/null 2>&1; then
  echo "-- installiere docker --"
  curl -fsSL https://get.docker.com | sh
fi
docker version >/dev/null

# 2. Images für den Kerberos-E2E vorziehen (macht den E2E-Lauf schnell)
#    samba-dc = KDC + AD-LDAP + interner DNS; nginx = origin (200); ubuntu = test-client
docker pull ubuntu:24.04            || true
docker pull nowsci/samba-domain     || true
docker pull nginx:alpine            || true

# 3. Data-Plane-Image bauen — erst wenn das P1-Template existiert
if [ -f image/templates/squid.conf.template ]; then
  echo "-- baue linuxmuster-squid:dev --"
  docker build -t linuxmuster-squid:dev image/
else
  echo "-- überspringe Image-Build: image/templates/squid.conf.template fehlt (kommt in P1) --"
fi

echo "== bootstrap fertig =="
