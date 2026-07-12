#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Orchestrates the Kerberos E2E: bring up the Samba AD DC, create fixtures
# (users/group/SPN/keytab/DNS), start Squid + origin, run assertions.
# Exit code = number of failed assertions (0 = green). Requires Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/deploy/e2e/docker-compose.yml"
# Docker directly or via sudo (the crabbox user may not be in the docker group)
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
DC="$DOCKER compose -f $CF"
DLC="example.internal"
PW="Passw0rd!"
SQUID_IP="172.28.0.10"
ORIGIN_IP="172.28.0.20"

log(){ printf '\n== %s ==\n' "$1"; }
dcx(){ $DC exec -T samba-dc "$@"; }        # exec in the DC, no TTY

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
if [ "$ready" != 1 ]; then echo "DC not ready"; $DC logs samba-dc 2>/dev/null | tail -40; exit 1; fi

log "fixtures: users, group, SPN, keytab, DNS"
dcx samba-tool user  create teacher1 "$PW"          >/dev/null 2>&1 || true
dcx samba-tool user  create student1 "$PW"          >/dev/null 2>&1 || true
dcx samba-tool user  create squidsvc "$PW"          >/dev/null 2>&1 || true
dcx samba-tool group add teachers                   >/dev/null 2>&1 || true
dcx samba-tool group addmembers teachers teacher1   >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid.$DLC" squidsvc >/dev/null 2>&1 || true
# Keytab for the KINIT-capable account principal (squidsvc), not just the HTTP SPN:
# the group helper uses it to authenticate against LDAP. The HTTP/squid SPN uses the same
# account key, so Negotiate (-s GSS_C_NO_NAME) decrypts the client tickets.
dcx samba-tool domain exportkeytab /shared/squid.keytab --principal=squidsvc || { echo "keytab export failed"; exit 1; }
dcx chmod 0600 /shared/squid.keytab   # 0600: tests the production keytab path (proxy copy in the entrypoint)
dcx samba-tool dns add 127.0.0.1 "$DLC" squid  A "$SQUID_IP"  -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" origin A "$ORIGIN_IP"   -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" secure A 172.28.0.21    -U "Administrator%$PW" >/dev/null 2>&1 || true
# Multischool fixtures: 2nd school "schule2" with prefixed group + its own teacher
dcx samba-tool user  create teacher2 "$PW"                      >/dev/null 2>&1 || true
dcx samba-tool group add schule2-teachers                      >/dev/null 2>&1 || true
dcx samba-tool group addmembers schule2-teachers teacher2      >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid2.$DLC" squidsvc           >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" squid2 A 172.28.0.11   -U "Administrator%$PW" >/dev/null 2>&1 || true
# Internet-gate fixtures: 'internet' + 'schule2-internet' groups + 3 teachers that differ
# ONLY by internet membership (in internet / in schule2-internet / in none). squid-inet
# requires teachers AND (internet OR schule2-internet). The new SPN uses the squidsvc key.
dcx samba-tool group add internet                                >/dev/null 2>&1 || true
dcx samba-tool group add schule2-internet                        >/dev/null 2>&1 || true
dcx samba-tool user  create inetok "$PW"                         >/dev/null 2>&1 || true
dcx samba-tool user  create inetor "$PW"                         >/dev/null 2>&1 || true
dcx samba-tool user  create inetno "$PW"                         >/dev/null 2>&1 || true
dcx samba-tool group addmembers teachers "inetok,inetor,inetno"  >/dev/null 2>&1 || true
dcx samba-tool group addmembers internet inetok                  >/dev/null 2>&1 || true
dcx samba-tool group addmembers schule2-internet inetor          >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid3.$DLC" squidsvc             >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" squid3 A 172.28.0.12    -U "Administrator%$PW" >/dev/null 2>&1 || true

log "start origin + origin-https + squid + squid2 + squid-inet"
$DC up -d origin origin-https squid squid2 squid-inet || exit 1

wait_healthy() {
  local svc="$1" ready=0 st=none cid
  for _ in $(seq 1 40); do
    cid=$($DC ps -q "$svc" 2>/dev/null)
    st=$($DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)
    if [ "$st" = healthy ]; then ready=1; break; fi
    sleep 3
  done
  if [ "$ready" != 1 ]; then echo "$svc not healthy (status=$st)"; $DC logs "$svc" 2>/dev/null | tail -60; return 1; fi
}
log "wait for squid + squid2 + squid-inet healthy"
wait_healthy squid     || exit 1
wait_healthy squid2    || exit 1
wait_healthy squid-inet || exit 1

log "run assertions (test-client)"
$DC run --rm test-client
rc=$?

# Internet-gate live check: inetok was allowed (in 'internet'); remove -> after the short
# ACL ttl (30s) new requests must be DENIED (Internetsperre, fail-closed).
log "internet-gate: remove inetok from 'internet', wait > ttl(30s), expect 403"
dcx samba-tool group removemembers internet inetok >/dev/null 2>&1 || true
sleep 40
tcode=$($DC run --rm --entrypoint sh test-client -c \
  'export KRB5CCNAME=FILE:/tmp/cc; printf %s "Passw0rd!" | kinit inetok@EXAMPLE.INTERNAL >/dev/null 2>&1; curl -s -o /dev/null -w "%{http_code}" --proxy http://squid3.example.internal:3128 --proxy-negotiate -U : http://origin.example.internal/' \
  2>/dev/null | tr -cd '0-9')
if [ "$tcode" = 403 ]; then
  echo "  [PASS] internetsperre: 403 within ~ttl after removal"
else
  echo "  [FAIL] internetsperre: expected 403, got '$tcode'"; rc=$((rc + 1))
fi

log "squid access.log (excerpt)"
$DC exec -T squid sh -c 'tail -20 /var/log/squid/access.log' 2>/dev/null \
  || $DC logs squid 2>/dev/null | tail -20 || true

log "squid cache.log (last lines, useful on error)"
$DC exec -T squid sh -c 'tail -25 /var/log/squid/cache.log' 2>/dev/null || true

exit "$rc"
