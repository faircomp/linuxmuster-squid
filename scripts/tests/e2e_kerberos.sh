#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Orchestriert den Kerberos-E2E: Samba-AD-DC hochfahren, Fixtures anlegen
# (Users/Gruppe/SPN/Keytab/DNS), Squid + origin starten, Assertions fahren.
# Exit-Code = Anzahl fehlgeschlagener Assertions (0 = grün). Braucht Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/deploy/e2e/docker-compose.yml"
DC="docker compose -f $CF"
DLC="example.internal"
PW="Passw0rd!"
SQUID_IP="172.28.0.10"
ORIGIN_IP="172.28.0.20"

log(){ printf '\n== %s ==\n' "$1"; }
dcx(){ $DC exec -T samba-dc "$@"; }        # exec im DC, kein TTY

cleanup(){ $DC down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "reset"
$DC down -v --remove-orphans >/dev/null 2>&1 || true

log "build squid image"
$DC build squid || exit 1

log "start samba-dc"
$DC up -d samba-dc || exit 1

log "wait for DC (KDC/LDAP/DNS)"
ready=0
for _ in $(seq 1 60); do
  if dcx samba-tool user list >/dev/null 2>&1; then ready=1; break; fi
  sleep 3
done
if [ "$ready" != 1 ]; then echo "DC nicht bereit"; $DC logs samba-dc 2>/dev/null | tail -40; exit 1; fi

log "fixtures: users, group, SPN, keytab, DNS"
dcx samba-tool user  create teacher1 "$PW"          >/dev/null 2>&1 || true
dcx samba-tool user  create student1 "$PW"          >/dev/null 2>&1 || true
dcx samba-tool user  create squidsvc "$PW"          >/dev/null 2>&1 || true
dcx samba-tool group add teachers                   >/dev/null 2>&1 || true
dcx samba-tool group addmembers teachers teacher1   >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid.$DLC" squidsvc >/dev/null 2>&1 || true
dcx samba-tool domain exportkeytab /shared/squid.keytab --principal="HTTP/squid.$DLC" || { echo "keytab-Export fehlgeschlagen"; exit 1; }
dcx chmod 0644 /shared/squid.keytab
dcx samba-tool dns add 127.0.0.1 "$DLC" squid  A "$SQUID_IP"  -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" origin A "$ORIGIN_IP" -U "Administrator%$PW" >/dev/null 2>&1 || true

log "start origin + squid"
$DC up -d origin squid || exit 1

log "wait for squid healthy"
ready=0; st=none
for _ in $(seq 1 40); do
  cid=$($DC ps -q squid 2>/dev/null)
  st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)
  if [ "$st" = healthy ]; then ready=1; break; fi
  sleep 3
done
if [ "$ready" != 1 ]; then echo "squid nicht healthy (status=$st)"; $DC logs squid 2>/dev/null | tail -60; exit 1; fi

log "run assertions (test-client)"
$DC run --rm test-client
rc=$?

log "squid access.log (Auszug)"
$DC logs squid 2>/dev/null | grep -Ei 'teacher1|student1|DENIED|407|403|200' | tail -20 || true

exit "$rc"
