#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke gegen den E2E-Samba-DC: discover-ad-facts.sh findet die Rollen-Gruppen
# (unpräfixiert + präfixiert) und erzeugt die passenden create-Skelette. Braucht Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/deploy/e2e/docker-compose.yml"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
DC="$DOCKER compose -f $CF"
fail=0

dcx(){ $DC exec -T samba-dc "$@"; }
pass(){ echo "  [PASS] $1"; }
bad(){ echo "  [FAIL] $1"; fail=$((fail + 1)); }
cleanup(){ $DC down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== reset + start samba-dc =="
$DC down -v --remove-orphans >/dev/null 2>&1 || true
$DC build samba-dc >/dev/null 2>&1 || true
$DC up -d samba-dc || exit 1
ready=0
for _ in $(seq 1 60); do dcx samba-tool user list >/dev/null 2>&1 && { ready=1; break; }; sleep 3; done
[ "$ready" = 1 ] || { echo "DC nicht bereit"; exit 1; }

echo "== fixtures: teachers + students (default) + schule2-teachers (präfixiert) =="
dcx samba-tool group add teachers          >/dev/null 2>&1 || true
dcx samba-tool group add students          >/dev/null 2>&1 || true
dcx samba-tool group add schule2-teachers  >/dev/null 2>&1 || true
sleep 5   # Settle: frisch angelegte Gruppen sind indiziert (Test-Artefakt; real existieren sie längst)

echo "== discover-ad-facts.sh im DC ausführen (REALM=EXAMPLE.INTERNAL) =="
CID="$($DC ps -q samba-dc)"
$DOCKER cp "$ROOT/scripts/discover-ad-facts.sh" "$CID:/tmp/disc.sh"
dcx env REALM=EXAMPLE.INTERNAL bash /tmp/disc.sh | tee /tmp/disc_out.txt

echo "== Assertions =="
grep -qE '^  - teachers$'          /tmp/disc_out.txt && pass "Gruppe teachers"          || bad "teachers fehlt"
grep -qE '^  - schule2-teachers$'  /tmp/disc_out.txt && pass "Gruppe schule2-teachers"  || bad "schule2-teachers fehlt"
grep -q 'create --school default-school --role teachers --ad-group teachers' /tmp/disc_out.txt && pass "create-Vorlage default-school" || bad "create default-school"
grep -q 'create --school schule2 --role teachers --ad-group schule2-teachers' /tmp/disc_out.txt && pass "create-Vorlage schule2"       || bad "create schule2"

echo "== discover-ad-facts smoke: $fail Fehler =="
exit "$fail"
