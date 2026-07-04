#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# crabbox smoke: builds the .deb, installs it, checks systemd + API + CLI and
# tests an upgrade. RUN AS ROOT (sudo bash scripts/tests/deb_smoke.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "== clean slate: remove any prior installation (hardened against box reuse) =="
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

echo "== CLI 'lmnsquid health' (reads /etc/linuxmuster-squid/config.yml) =="
sudo -u lmnsquid /opt/linuxmuster-squid/venv/bin/lmnsquid health

echo "== instances_dir is a git repo (change log)? =="
if sudo -u lmnsquid git -C /var/lib/linuxmuster-squid/instances rev-parse --git-dir >/dev/null 2>&1; then
    echo "  [PASS] instances_dir git-initialized"
else
    echo "  [FAIL] no git repo in instances_dir"; exit 1
fi

PID_BEFORE="$(systemctl show -p MainPID --value linuxmuster-squid.service)"
echo "== Upgrade to 0.9.1 (MainPID before=$PID_BEFORE) =="
VERSION=0.9.1 bash "$ROOT/packaging/build-deb.sh"
apt-get install -y -q "$ROOT/linuxmuster-squid_0.9.1_all.deb" \
    || dpkg -i "$ROOT/linuxmuster-squid_0.9.1_all.deb"
sleep 4
systemctl is-active linuxmuster-squid.service
dpkg -s linuxmuster-squid | grep '^Version:'

echo "== Upgrade restarted the service? (= new code loaded) =="
PID_AFTER="$(systemctl show -p MainPID --value linuxmuster-squid.service)"
echo "  MainPID before=$PID_BEFORE after=$PID_AFTER"
if [ -n "$PID_AFTER" ] && [ "$PID_AFTER" != 0 ] && [ "$PID_AFTER" != "$PID_BEFORE" ]; then
    echo "  [PASS] Upgrade restarted -> new code active"
else
    echo "  [FAIL] Upgrade did NOT restart (MainPID unchanged) -> old code would stay active"
    exit 1
fi

echo "== deb smoke OK =="
