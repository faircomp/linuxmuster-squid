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

# The image installed systems run: DEFAULT_IMAGE of the control plane (squid-pinned service).
LMNSQUID_PINNED_IMAGE="$(sed -n 's/^ *"\(ghcr\.io\/[^"]*\)"$/\1/p; s/^ *"\(@sha256:[0-9a-f]*\)"$/\1/p' \
  "$ROOT/controlplane/lmnsquid/models.py" | tr -d '\n')"
case "$LMNSQUID_PINNED_IMAGE" in
  ghcr.io/*@sha256:*) export LMNSQUID_PINNED_IMAGE ;;
  *) echo "cannot read DEFAULT_IMAGE from models.py (got '$LMNSQUID_PINNED_IMAGE')"; exit 1 ;;
esac

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

# Domains without proxy auth (ADR-016): squid4 = squid-noauth, squid5 = the pinned image;
# more names on the HTTPS origin (a listed subdomain, an unlisted name).
dcx samba-tool spn   add "HTTP/squid4.$DLC" squidsvc             >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid5.$DLC" squidsvc             >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" squid4 A 172.28.0.13    -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" squid5 A 172.28.0.14    -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" www.secure A 172.28.0.21 -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" secure2 A 172.28.0.21   -U "Administrator%$PW" >/dev/null 2>&1 || true

log "start origin + origin-https + squid + squid2 + squid-inet + squid-noauth + squid-pinned"
$DC up -d origin origin-https squid squid2 squid-inet squid-noauth squid-pinned || exit 1

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
wait_healthy squid-noauth || exit 1
wait_healthy squid-pinned || exit 1

log "run assertions (test-client)"
$DC run --rm test-client
rc=$?

# Internet-gate live check: inetok was allowed (in 'internet'); remove -> after the short
# ACL ttl (30s) new requests must be DENIED (Internetsperre, fail-closed).
log "internet-gate: remove inetok from 'internet', wait > ttl(10s), expect 403"
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

# Outside school_net (squid-noauth admits 172.28.0.30/32 only): from the squid container
# (172.28.0.10) a listed domain without a ticket must still get 407, plain HTTP and CONNECT.
log "noauth: request from outside school_net, no ticket -> 407"
for req in "http://secure.example.internal/" "-m CONNECT secure.example.internal:443"; do
  # shellcheck disable=SC2086  # $req carries squidclient's options on purpose
  line=$($DC exec -T squid squidclient -T 10 -h 172.28.0.13 -p 3128 $req 2>/dev/null | head -1 | tr -d '\r')
  case "$line" in
    *" 407 "*) echo "  [PASS] outside school_net: $req -> $line" ;;
    *) echo "  [FAIL] outside school_net: $req: expected 407, got '$line'"; rc=$((rc + 1)) ;;
  esac
done
# squid2 got a list directory without noauth.domains (older control plane): the entrypoint
# says so and stands in an empty list.
# (grep without -q: an early exit would SIGPIPE `compose logs`, a failure under pipefail)
if $DC logs squid2 2>/dev/null | grep 'no /etc/squid/lists/noauth.domains' >/dev/null; then
  echo "  [PASS] list directory without noauth.domains: empty list, notice logged"
else
  echo "  [FAIL] squid2: notice about the missing noauth.domains not logged"; rc=$((rc + 1))
fi

# squid-noauth's mounted lists hold entries squid 6 refuses to load next to their parent
# (hand-edited): lists-sync.sh must have dropped them (logged), the instance must reload and
# come back after a restart (before, such a list stopped squid: "FATAL: Bungled").
log "lists with covered entries: logged, reload, restart"
if $DC logs squid-noauth 2>/dev/null | grep 'entries ignored, already covered' >/dev/null; then
  echo "  [PASS] covered entries dropped and logged"
else
  echo "  [FAIL] no notice about covered entries"; rc=$((rc + 1))
fi
if $DC logs squid-noauth 2>/dev/null | grep 'noauth.domains: ignored, not a domain name: 172.28.0.20' >/dev/null; then
  echo "  [PASS] IP literal in noauth.domains ignored and logged"
else
  echo "  [FAIL] no notice about the IP literal in noauth.domains"; rc=$((rc + 1))
fi
if $DC exec -T squid-noauth sh -c '/usr/local/bin/lists-sync.sh 2>/dev/null && squid -k reconfigure -f /run/lmnsquid/squid.conf'; then
  echo "  [PASS] reload (lists-sync.sh + squid -k reconfigure) with these lists"
else
  echo "  [FAIL] reload with these lists"; rc=$((rc + 1))
fi
$DC restart squid-noauth >/dev/null 2>&1
if wait_healthy squid-noauth; then
  echo "  [PASS] squid-noauth healthy again after a restart"
else
  echo "  [FAIL] squid-noauth did not come back after a restart"; rc=$((rc + 1))
fi
code=$($DC run --rm --entrypoint sh test-client -c \
  'curl -s -o /dev/null -w "%{http_code}" --proxy http://squid4.example.internal:3128 http://secure.example.internal/' 2>/dev/null | tr -cd '0-9')
if [ "$code" = 200 ]; then
  echo "  [PASS] after the restart: listed, no ticket -> 200"
else
  echo "  [FAIL] after the restart: expected 200, got '$code'"; rc=$((rc + 1))
fi

log "squid-noauth access.log (excerpt)"
$DC exec -T squid-noauth sh -c 'tail -25 /var/log/squid/access.log' 2>/dev/null || true

log "squid access.log (excerpt)"
$DC exec -T squid sh -c 'tail -20 /var/log/squid/access.log' 2>/dev/null \
  || $DC logs squid 2>/dev/null | tail -20 || true

log "squid cache.log (last lines, useful on error)"
$DC exec -T squid sh -c 'tail -25 /var/log/squid/cache.log' 2>/dev/null || true

exit "$rc"
