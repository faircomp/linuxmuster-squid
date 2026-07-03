#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke gegen den E2E-Samba-DC: provision-keytab.sh ist idempotent und bricht bei
# einem Duplicate-SPN (gleicher SPN auf einem anderen Konto) sauber ab. Braucht Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/deploy/e2e/docker-compose.yml"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
DC="$DOCKER compose -f $CF"
PW="Passw0rd!"
FQDN="ktest.example.internal"
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

echo "== fixtures: zwei Dienstkonten =="
dcx samba-tool user create ktsvc1 "$PW" >/dev/null 2>&1 || true
dcx samba-tool user create ktsvc2 "$PW" >/dev/null 2>&1 || true

echo "== provision-keytab.sh in den DC kopieren =="
CID="$($DC ps -q samba-dc)"
$DOCKER cp "$ROOT/scripts/provision-keytab.sh" "$CID:/tmp/pk.sh"

echo "== A: erster Lauf (ktsvc1) =="
if dcx bash /tmp/pk.sh "$FQDN" ktsvc1 /tmp/kt1.keytab; then pass "erster Lauf erfolgreich"; else bad "erster Lauf"; fi
if dcx test -s /tmp/kt1.keytab; then pass "keytab erzeugt"; else bad "keytab fehlt"; fi

echo "== B: zweiter Lauf (ktsvc1) -> idempotent =="
if dcx bash /tmp/pk.sh "$FQDN" ktsvc1 /tmp/kt1b.keytab; then pass "zweiter Lauf idempotent (exit 0)"; else bad "zweiter Lauf nicht idempotent"; fi

echo "== C: gleicher SPN auf ktsvc2 -> Duplicate-SPN-Abbruch =="
if dcx bash /tmp/pk.sh "$FQDN" ktsvc2 /tmp/kt2.keytab; then bad "duplicate SPN NICHT abgebrochen"; else pass "duplicate SPN bricht ab (exit != 0)"; fi

echo "== provision-keytab smoke: $fail Fehler =="
exit "$fail"
