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
# Docker direkt oder via sudo (crabbox-User ist evtl. nicht in der docker-Gruppe)
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
DC="$DOCKER compose -f $CF"
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

log "build images (squid, origin-https, test-client)"
$DC build || exit 1

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
# Keytab für den KINIT-fähigen Account-Principal (squidsvc), nicht nur den HTTP-SPN:
# der Gruppen-Helper meldet sich damit am LDAP an. Der HTTP/squid-SPN nutzt denselben
# Account-Schlüssel, daher entschlüsselt Negotiate (-s GSS_C_NO_NAME) die Client-Tickets.
dcx samba-tool domain exportkeytab /shared/squid.keytab --principal=squidsvc || { echo "keytab-Export fehlgeschlagen"; exit 1; }
dcx chmod 0600 /shared/squid.keytab   # 0600: testet den Produktions-Keytab-Pfad (proxy-Kopie im Entrypoint)
dcx samba-tool dns add 127.0.0.1 "$DLC" squid  A "$SQUID_IP"  -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" origin A "$ORIGIN_IP"   -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" secure A 172.28.0.21    -U "Administrator%$PW" >/dev/null 2>&1 || true
# Multischool-Fixtures: 2. Schule "schule2" mit präfixierter Gruppe + eigenem Lehrer
dcx samba-tool user  create teacher2 "$PW"                      >/dev/null 2>&1 || true
dcx samba-tool group add schule2-teachers                      >/dev/null 2>&1 || true
dcx samba-tool group addmembers schule2-teachers teacher2      >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid2.$DLC" squidsvc           >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" squid2 A 172.28.0.11   -U "Administrator%$PW" >/dev/null 2>&1 || true

log "start origin + origin-https + squid + squid2"
$DC up -d origin origin-https squid squid2 || exit 1

wait_healthy() {
  local svc="$1" ready=0 st=none cid
  for _ in $(seq 1 40); do
    cid=$($DC ps -q "$svc" 2>/dev/null)
    st=$($DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)
    if [ "$st" = healthy ]; then ready=1; break; fi
    sleep 3
  done
  if [ "$ready" != 1 ]; then echo "$svc nicht healthy (status=$st)"; $DC logs "$svc" 2>/dev/null | tail -60; return 1; fi
}
log "wait for squid + squid2 healthy"
wait_healthy squid  || exit 1
wait_healthy squid2 || exit 1

log "run assertions (test-client)"
$DC run --rm test-client
rc=$?

log "squid access.log (Auszug)"
$DC exec -T squid sh -c 'tail -20 /var/log/squid/access.log' 2>/dev/null \
  || $DC logs squid 2>/dev/null | tail -20 || true

log "squid cache.log (letzte Zeilen, bei Fehler nützlich)"
$DC exec -T squid sh -c 'tail -25 /var/log/squid/cache.log' 2>/dev/null || true

exit "$rc"
