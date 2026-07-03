#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# crabbox-Smoke: baut das .deb, installiert es, prüft systemd + API + CLI und
# testet ein Upgrade. ALS ROOT ausführen (sudo bash scripts/tests/deb_smoke.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "== clean slate: evtl. Vorinstallation entfernen (fest gegen Box-Reuse) =="
dpkg --purge linuxmuster-squid >/dev/null 2>&1 || true

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

echo "== instances_dir ist ein git-Repo (Change-Log)? =="
if sudo -u lmnsquid git -C /var/lib/linuxmuster-squid/instances rev-parse --git-dir >/dev/null 2>&1; then
    echo "  [PASS] instances_dir git-initialisiert"
else
    echo "  [FAIL] kein git-Repo in instances_dir"; exit 1
fi

PID_BEFORE="$(systemctl show -p MainPID --value linuxmuster-squid.service)"
echo "== Upgrade auf 0.9.1 (MainPID vorher=$PID_BEFORE) =="
VERSION=0.9.1 bash "$ROOT/packaging/build-deb.sh"
apt-get install -y -q "$ROOT/linuxmuster-squid_0.9.1_all.deb" \
    || dpkg -i "$ROOT/linuxmuster-squid_0.9.1_all.deb"
sleep 4
systemctl is-active linuxmuster-squid.service
dpkg -s linuxmuster-squid | grep '^Version:'

echo "== Upgrade hat den Dienst neu gestartet? (= neuer Code geladen) =="
PID_AFTER="$(systemctl show -p MainPID --value linuxmuster-squid.service)"
echo "  MainPID vorher=$PID_BEFORE nachher=$PID_AFTER"
if [ -n "$PID_AFTER" ] && [ "$PID_AFTER" != 0 ] && [ "$PID_AFTER" != "$PID_BEFORE" ]; then
    echo "  [PASS] Upgrade hat neu gestartet -> neuer Code aktiv"
else
    echo "  [FAIL] Upgrade hat NICHT neu gestartet (MainPID unverändert) -> alter Code bliebe aktiv"
    exit 1
fi

echo "== deb smoke OK =="
