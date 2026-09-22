#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke against the E2E Samba DC: discover-ad-facts.sh lists the global role groups and
# the internet groups (and nothing that merely ends in -students) and generates the two
# create commands. Requires Docker.
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
[ "$ready" = 1 ] || { echo "DC not ready"; exit 1; }

echo "== fixtures: role-teacher/role-student (global), internet + schule2-internet, a class group =="
for g in role-teacher role-student internet schule2-internet 5a-students; do
    dcx samba-tool group add "$g" >/dev/null 2>&1 || true
done
sleep 5   # Settle: freshly created groups are indexed (test artifact; in reality they exist already)

echo "== run discover-ad-facts.sh inside the DC (REALM=EXAMPLE.INTERNAL) =="
CID="$($DC ps -q samba-dc)"
$DOCKER cp "$ROOT/scripts/discover-ad-facts.sh" "$CID:/tmp/disc.sh"
dcx env REALM=EXAMPLE.INTERNAL bash /tmp/disc.sh | tee /tmp/disc_out.txt

echo "== Assertions =="
grep -qE '^  - role-teacher$'     /tmp/disc_out.txt && pass "group role-teacher"     || bad "role-teacher missing"
grep -qE '^  - role-student$'     /tmp/disc_out.txt && pass "group role-student"     || bad "role-student missing"
grep -qE '^  - internet$'         /tmp/disc_out.txt && pass "group internet"         || bad "internet missing"
grep -qE '^  - schule2-internet$' /tmp/disc_out.txt && pass "group schule2-internet" || bad "schule2-internet missing"
grep -q  '5a-students'            /tmp/disc_out.txt && bad "class group listed"      || pass "class group not listed"
grep -q 'create --school all --role teachers --ad-group role-teacher' /tmp/disc_out.txt && pass "create template teachers" || bad "create teachers"
grep -q 'create --school all --role students --ad-group role-student' /tmp/disc_out.txt && pass "create template students" || bad "create students"
grep -q -- '--internet-group internet --internet-group schule2-internet' /tmp/disc_out.txt && pass "internet groups in template" || bad "internet groups missing"

echo "== discover-ad-facts smoke: $fail errors =="
exit "$fail"
