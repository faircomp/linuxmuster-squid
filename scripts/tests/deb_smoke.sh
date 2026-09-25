#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# crabbox smoke: builds the .deb, installs it, checks systemd + API + CLI and
# tests an upgrade onto a second build of the same tree one version higher
# (<changelog version>+smoke1). RUN AS ROOT (sudo bash scripts/tests/deb_smoke.sh).
# `make deb` (dpkg-buildpackage) writes its results one level above the source tree, so
# both builds run in copies under a temporary directory, never in the checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
VERSION="$(dpkg-parsechangelog -l "$ROOT/debian/changelog" -S Version)"

echo "== clean slate: remove any prior installation (hardened against box reuse) =="
dpkg --purge linuxmuster-squid >/dev/null 2>&1 || true

echo "== build dependencies (debian/control) =="
apt-get update -qq
(cd "$ROOT" && apt-get build-dep -y -q .)

# build <dir> [version]: `make deb` in a copy of the tree; with a version, that copy gets one
# changelog entry on top, so the package (and the lmnsquid wheel) carry it.
build() {
    local dir=$1 version=${2:-}
    mkdir -p "$dir/src"
    tar -C "$ROOT" --exclude=./.git --exclude=./.venv -cf - . | tar -C "$dir/src" -xf -
    if [ -n "$version" ]; then
        { printf 'linuxmuster-squid (%s) lmn73; urgency=medium\n\n' "$version"
          printf '  * deb_smoke.sh: upgrade test build.\n\n'
          printf ' -- Kevin Stenzel <mail@kevin-stenzel.de>  %s\n\n' "$(date -R)"
          cat "$dir/src/debian/changelog"; } > "$dir/changelog"
        mv "$dir/changelog" "$dir/src/debian/changelog"
    fi
    (cd "$dir/src" && make deb) > "$dir/build.log" 2>&1 || { tail -n 40 "$dir/build.log"; return 1; }
}

echo "== build .deb ($VERSION) =="
build "$WORK/a"
DEB="$WORK/a/linuxmuster-squid_${VERSION}_amd64.deb"

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
NEXT="$VERSION+smoke1"
echo "== Upgrade to $NEXT (MainPID before=$PID_BEFORE) =="
build "$WORK/b" "$NEXT"
apt-get install -y -q "$WORK/b/linuxmuster-squid_${NEXT}_amd64.deb" \
    || dpkg -i "$WORK/b/linuxmuster-squid_${NEXT}_amd64.deb"
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
