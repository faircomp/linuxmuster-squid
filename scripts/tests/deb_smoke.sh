#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# crabbox-Smoke: baut das .deb, installiert es, prüft systemd + API + CLI und
# testet ein Upgrade. ALS ROOT ausführen (sudo bash scripts/tests/deb_smoke.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "== build .deb (0.9.0) =="
VERSION=0.9.0 bash "$ROOT/packaging/build-deb.sh"
DEB="$ROOT/linuxmuster-squid_0.9.0_all.deb"

echo "== install =="
apt-get install -y -q "$DEB" || { dpkg -i "$DEB" || true; apt-get -y -f install; }

echo "== systemd active? =="
sleep 4
systemctl is-active linuxmuster-squid.service

echo "== API /v1/health (localhost) =="
curl -fsS http://127.0.0.1:8080/v1/health; echo

echo "== CLI 'lmnsquid health' (liest /etc/linuxmuster-squid/config.yml) =="
sudo -u lmnsquid /opt/linuxmuster-squid/venv/bin/lmnsquid health

echo "== Upgrade auf 0.9.1 =="
VERSION=0.9.1 bash "$ROOT/packaging/build-deb.sh"
apt-get install -y -q "$ROOT/linuxmuster-squid_0.9.1_all.deb" \
    || dpkg -i "$ROOT/linuxmuster-squid_0.9.1_all.deb"
sleep 4
systemctl is-active linuxmuster-squid.service
dpkg -s linuxmuster-squid | grep '^Version:'

echo "== deb smoke OK =="
