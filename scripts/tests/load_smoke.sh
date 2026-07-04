#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Load smoke: "whole class at once" — N parallel Kerberos auth requests from one
# teacher through ONE instance. Verifies that negotiate_kerberos_auth (children) +
# ext_kerberos_ldap_group_acl handle the concurrency without 5xx. Needs Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CF="$ROOT/deploy/e2e/docker-compose.yml"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
DC="$DOCKER compose -f $CF"
DLC="example.internal"; REALM="EXAMPLE.INTERNAL"; PW="Passw0rd!"
SQUID_IP="172.28.0.10"; ORIGIN_IP="172.28.0.20"
N="${LOAD_N:-50}"

dcx(){ $DC exec -T samba-dc "$@"; }
cleanup(){ $DC down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== reset + build + start samba-dc =="
$DC down -v --remove-orphans >/dev/null 2>&1 || true
$DC build >/dev/null 2>&1 || { echo "build failed"; $DC build; exit 1; }
$DC up -d samba-dc || exit 1
ready=0
for _ in $(seq 1 60); do dcx samba-tool user list >/dev/null 2>&1 && { ready=1; break; }; sleep 3; done
[ "$ready" = 1 ] || { echo "DC not ready"; exit 1; }

echo "== fixtures (teacher1, squidsvc, teachers, SPN, keytab, DNS) =="
dcx samba-tool user  create teacher1 "$PW"          >/dev/null 2>&1 || true
dcx samba-tool user  create squidsvc "$PW"          >/dev/null 2>&1 || true
dcx samba-tool group add teachers                   >/dev/null 2>&1 || true
dcx samba-tool group addmembers teachers teacher1   >/dev/null 2>&1 || true
dcx samba-tool spn   add "HTTP/squid.$DLC" squidsvc >/dev/null 2>&1 || true
dcx samba-tool domain exportkeytab /shared/squid.keytab --principal=squidsvc \
    || { echo "keytab export failed"; exit 1; }
dcx chmod 0600 /shared/squid.keytab
dcx samba-tool dns add 127.0.0.1 "$DLC" squid  A "$SQUID_IP"  -U "Administrator%$PW" >/dev/null 2>&1 || true
dcx samba-tool dns add 127.0.0.1 "$DLC" origin A "$ORIGIN_IP" -U "Administrator%$PW" >/dev/null 2>&1 || true

echo "== start origin + squid, wait for healthy =="
$DC up -d origin squid || exit 1
ok=0
for _ in $(seq 1 40); do
    cid=$($DC ps -q squid 2>/dev/null)
    st=$($DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)
    [ "$st" = healthy ] && { ok=1; break; }; sleep 3
done
[ "$ok" = 1 ] || { echo "squid not healthy"; $DC logs squid 2>/dev/null | tail -30; exit 1; }

echo "== LOAD: $N parallel curl --proxy-negotiate (teacher1) through squid.$DLC =="
OUT="$($DC run --rm -T --entrypoint sh \
    -e LOAD_N="$N" -e LOAD_PW="$PW" -e LOAD_REALM="$REALM" -e LOAD_DLC="$DLC" \
    test-client -c '
        printf "%s" "$LOAD_PW" | kinit "teacher1@$LOAD_REALM" 2>/dev/null
        : > /tmp/codes
        i=0
        while [ "$i" -lt "$LOAD_N" ]; do
            curl -s -o /dev/null -w "%{http_code}\n" --proxy-negotiate -U : \
                -x "http://squid.$LOAD_DLC:3128" "http://origin.$LOAD_DLC/" >> /tmp/codes 2>/dev/null &
            i=$((i + 1))
        done
        wait
        echo "LOAD_RESULT ok=$(grep -c "^200" /tmp/codes) tot=$(wc -l < /tmp/codes) s5=$(grep -c "^5" /tmp/codes)"
    ' 2>/dev/null)"
printf '%s\n' "$OUT" | grep -a LOAD_RESULT || true

line="$(printf '%s\n' "$OUT" | grep -a LOAD_RESULT | tail -1)"
okc=$(printf '%s' "$line" | sed -n 's/.*ok=\([0-9]*\).*/\1/p')
totc=$(printf '%s' "$line" | sed -n 's/.*tot=\([0-9]*\).*/\1/p')
s5c=$(printf '%s' "$line" | sed -n 's/.*s5=\([0-9]*\).*/\1/p')
: "${okc:=0}" "${totc:=0}" "${s5c:=1}"

fail=0
echo "== Evaluation: $okc/$totc with 200, $s5c 5xx (N=$N) =="
# Success: no 5xx AND >=95% of requests 200 (Kerberos concurrency holds).
if [ "$totc" -ge "$N" ] && [ "$s5c" = 0 ] && [ "$okc" -ge $(( N * 95 / 100 )) ]; then
    echo "  [PASS] class load ($N concurrent) handled without 5xx"
else
    echo "  [FAIL] load not handled cleanly (ok=$okc tot=$totc s5=$s5c)"; fail=1
    $DC logs squid 2>/dev/null | tail -20
fi
echo "== load smoke: $fail errors =="
exit "$fail"
