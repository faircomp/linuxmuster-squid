#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke against the E2E Samba DC: provision-keytab.sh is idempotent and aborts cleanly on
# a duplicate SPN (same SPN on a different account). Needs Docker.
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
[ "$ready" = 1 ] || { echo "DC not ready"; exit 1; }

echo "== fixtures: two service accounts =="
dcx samba-tool user create ktsvc1 "$PW" >/dev/null 2>&1 || true
dcx samba-tool user create ktsvc2 "$PW" >/dev/null 2>&1 || true

echo "== copy provision-keytab.sh into the DC =="
CID="$($DC ps -q samba-dc)"
$DOCKER cp "$ROOT/scripts/provision-keytab.sh" "$CID:/tmp/pk.sh"

echo "== A: first run (ktsvc1) =="
if dcx bash /tmp/pk.sh "$FQDN" ktsvc1 /tmp/kt1.keytab; then pass "first run succeeded"; else bad "first run"; fi
if dcx test -s /tmp/kt1.keytab; then pass "keytab created"; else bad "keytab missing"; fi

echo "== B: second run (ktsvc1) -> idempotent =="
if dcx bash /tmp/pk.sh "$FQDN" ktsvc1 /tmp/kt1b.keytab; then pass "second run idempotent (exit 0)"; else bad "second run not idempotent"; fi

echo "== C: same SPN on ktsvc2 -> duplicate SPN abort =="
if dcx bash /tmp/pk.sh "$FQDN" ktsvc2 /tmp/kt2.keytab; then bad "duplicate SPN NOT aborted"; else pass "duplicate SPN aborts (exit != 0)"; fi

echo "== provision-keytab smoke: $fail errors =="
exit "$fail"
