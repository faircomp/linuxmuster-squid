#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The four E2E assertions. Runs in the test-client container.
# Proves authN vs. authZ via the HTTP codes: 200 / 403 / 403 / 407.
set -uo pipefail

PROXY="http://squid.example.internal:3128"
ALLOWED="http://origin.example.internal/"
BLOCKED="http://blocked.example.com/"
REALM="EXAMPLE.INTERNAL"
PW="Passw0rd!"
export KRB5CCNAME="FILE:/tmp/cc"   # no kernel keyring in the unprivileged container

fail=0

# check <description> <user|""> <url> <expected-code>
check() {
  local desc="$1" user="$2" url="$3" exp="$4" code
  kdestroy -q 2>/dev/null || true
  if [ -n "$user" ]; then
    if ! printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1; then
      echo "  [FAIL] $desc: kinit $user failed"; fail=1; return
    fi
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' \
              --proxy "$PROXY" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" = "$exp" ]; then
    echo "  [PASS] $desc ($code)"
  else
    echo "  [FAIL] $desc: expected $exp, got $code"; fail=1
  fi
}

# HTTPS check (self-signed origin -> -k). Expects an exact code.
check_https() {
  local desc="$1" user="$2" url="$3" exp="$4" code
  kdestroy -q 2>/dev/null || true
  if [ -n "$user" ]; then
    printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1 || { echo "  [FAIL] $desc: kinit $user"; fail=1; return; }
  fi
  code=$(curl -sk -o /dev/null -w '%{http_code}' --proxy "$PROXY" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" = "$exp" ]; then echo "  [PASS] $desc ($code)"; else echo "  [FAIL] $desc: expected $exp, got $code"; fail=1; fi
}

# HTTPS blocked -> code must NOT be 200 (CONNECT deny or SNI terminate).
check_https_blocked() {
  local desc="$1" user="$2" url="$3" code
  kdestroy -q 2>/dev/null || true
  printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1 || { echo "  [FAIL] $desc: kinit $user"; fail=1; return; }
  code=$(curl -sk -o /dev/null -w '%{http_code}' --proxy "$PROXY" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" != "200" ]; then echo "  [PASS] $desc (blocked, code=$code)"; else echo "  [FAIL] $desc: unexpected 200"; fail=1; fi
}

# Check via a specific proxy (multischool: different instances/schools).
check_via() {
  local desc="$1" user="$2" proxy="$3" url="$4" exp="$5" code
  kdestroy -q 2>/dev/null || true
  if [ -n "$user" ]; then
    printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1 || { echo "  [FAIL] $desc: kinit $user"; fail=1; return; }
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' --proxy "$proxy" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" = "$exp" ]; then echo "  [PASS] $desc ($code)"; else echo "  [FAIL] $desc: expected $exp, got $code"; fail=1; fi
}

# HTTPS through a proxy: "<CONNECT code> <code behind the tunnel>" must equal <expected>
# (e.g. "200 200" = tunnel up and TLS done; "200 000" = tunnel up, TLS cut; "403 000").
check_tunnel() {
  local desc="$1" user="$2" proxy="$3" url="$4" exp="$5" got
  kdestroy -q 2>/dev/null || true
  if [ -n "$user" ]; then
    printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1 || { echo "  [FAIL] $desc: kinit $user"; fail=1; return; }
  fi
  got=$(curl -sk -o /dev/null -w '%{http_connect} %{http_code}' --max-time 15 \
             --proxy "$proxy" --proxy-negotiate -U : "$url" 2>/dev/null)
  if [ "$got" = "$exp" ]; then echo "  [PASS] $desc ($got)"; else echo "  [FAIL] $desc: expected '$exp', got '$got'"; fail=1; fi
}

# A TLS handshake through the proxy WITHOUT a ticket, with a chosen SNI (or none: "-"):
# <expected> = ok (server certificate received) or cut (no certificate: terminated).
check_tls_sni() {
  local desc="$1" proxy="$2" target="$3" sni="$4" exp="$5" got=cut
  local args=(-proxy "$proxy" -connect "$target")
  if [ "$sni" = "-" ]; then args+=(-noservername); else args+=(-servername "$sni"); fi
  kdestroy -q 2>/dev/null || true
  if timeout 20 openssl s_client "${args[@]}" </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
    got=ok
  fi
  if [ "$got" = "$exp" ]; then echo "  [PASS] $desc ($got)"; else echo "  [FAIL] $desc: expected $exp, got $got"; fail=1; fi
}

echo "== Kerberos E2E assertions =="
check "Teacher allowed"           teacher1 "$ALLOWED" 200
check "Student denied"       student1 "$ALLOWED" 403
check "Blocked domain (teacher)" teacher1 "$BLOCKED" 403
check "No ticket"              ""       "$ALLOWED" 407
check_https         "HTTPS allowed (teacher, splice)" teacher1 "https://secure.example.internal/" 200
check_https_blocked "HTTPS blocked (teacher)"        teacher1 "https://blocked.example.com/"
PROXY2="http://squid2.example.internal:3128"
check_via "Multischool: schule2 teacher via schule2 -> ok"   teacher2 "$PROXY2" "$ALLOWED" 200
check_via "Multischool: default teacher via schule2 -> deny" teacher1 "$PROXY2" "$ALLOWED" 403
check_via "Multischool: schule2 teacher via default -> deny" teacher2 "$PROXY"  "$ALLOWED" 403
# Internet gate (squid-inet requires teachers AND internet:schule2-internet):
PROXY3="http://squid3.example.internal:3128"
check_via "Internet-gate: teacher in 'internet' -> ok"          inetok "$PROXY3" "$ALLOWED" 200
check_via "Internet-gate OR: teacher in 'schule2-internet' -> ok" inetor "$PROXY3" "$ALLOWED" 200
check_via "Internet-gate: teacher in NO internet group -> deny" inetno "$PROXY3" "$ALLOWED" 403

# Domains without proxy auth (ADR-016). squid-noauth lists secure.example.internal and
# both.example.internal (the latter also blocked); school_net = this client (172.28.0.30).
NA="http://squid4.example.internal:3128"
NA_HOST="squid4.example.internal:3128"
echo "-- noauth (client $(hostname -I 2>/dev/null | tr -d ' '), school_net 172.28.0.30/32) --"
check_via    "noauth: listed HTTP, no ticket -> 200"              "" "$NA" "http://secure.example.internal/" 200
check_via    "noauth: listed subdomain, no ticket -> 200"         "" "$NA" "http://www.secure.example.internal/" 200
check_via    "noauth: not listed, no ticket -> 407"               "" "$NA" "$ALLOWED" 407
# squid-noauth knows 172.28.0.21 -> secure.example.internal (extra_hosts = its reverse
# cache): without dstdomain -n this IP-literal URL would match the list (200, measured).
check_via    "noauth: IP literal of a listed host -> 407"         "" "$NA" "http://172.28.0.21/" 407
check_via    "noauth: IP written into the list -> 407"           "" "$NA" "http://172.28.0.20/" 407
check_via    "noauth: listed AND blocked HTTP, no ticket -> 403"  "" "$NA" "http://both.example.internal/" 403
check_tunnel "noauth: listed HTTPS, no ticket -> tunnel + TLS"   "" "$NA" "https://secure.example.internal/" "200 200"
check_tunnel "noauth: not listed HTTPS, no ticket -> 407"         "" "$NA" "https://secure2.example.internal/" "407 000"
# A denied CONNECT on an ssl-bump port: squid answers the CONNECT and delivers its 403 page
# inside TLS with its throwaway certificate (browsers reject it: TLS error); curl -k shows it.
check_tunnel "noauth: listed AND blocked HTTPS -> denied (403)"   "" "$NA" "https://both.example.internal/" "200 403"
check_tls_sni "noauth: CONNECT listed, SNI listed -> handshake"      "$NA_HOST" secure.example.internal:443 secure.example.internal ok
check_tls_sni "noauth: CONNECT listed, foreign SNI -> cut"           "$NA_HOST" secure.example.internal:443 origin.example.internal cut
check_tls_sni "noauth: CONNECT listed, blocked SNI -> cut"           "$NA_HOST" secure.example.internal:443 blocked.example.com cut
check_tls_sni "noauth: CONNECT listed, no SNI -> cut"                "$NA_HOST" secure.example.internal:443 - cut
# With a ticket the instance behaves as before (the 200/403/407 matrix of install.md §6).
check_via    "noauth instance: teacher -> 200"                    teacher1 "$NA" "$ALLOWED" 200
check_via    "noauth instance: student -> 403"                    student1 "$NA" "$ALLOWED" 403
check_via    "noauth instance: blocked (teacher) -> 403"          teacher1 "$NA" "http://blocked.example.com/" 403
check_via    "noauth instance: blocked subdomain (teacher) -> 403" teacher1 "$NA" "http://a.blocked.example.com/" 403
check_via    "noauth instance: listed+blocked (teacher) -> 403"   teacher1 "$NA" "http://both.example.internal/" 403
check_via    "noauth instance: listed (teacher) -> 200"           teacher1 "$NA" "http://secure.example.internal/" 200
check_tunnel "noauth instance: HTTPS not listed (teacher) -> 200" teacher1 "$NA" "https://secure2.example.internal/" "200 200"
# An empty list (squid: the image's empty file) and a directory without the file (squid2,
# as an older control plane mounts it) change nothing:
check_via    "empty list: listed elsewhere, no ticket -> 407"     "" "$PROXY"  "http://secure.example.internal/" 407
check_via    "no list file: no ticket -> 407"                     "" "$PROXY2" "http://secure.example.internal/" 407
# The pinned image of installed systems with a directory that holds noauth.domains:
PROXY5="http://squid5.example.internal:3128"
check_via    "pinned image + noauth.domains: no ticket -> 407"    "" "$PROXY5" "http://secure.example.internal/" 407
check_via    "pinned image + noauth.domains: teacher -> 200"      teacher1 "$PROXY5" "http://secure.example.internal/" 200
check_via    "pinned image + noauth.domains: student -> 403"      student1 "$PROXY5" "$ALLOWED" 403

echo
if [ "$fail" -eq 0 ]; then echo "E2E: ALL ASSERTIONS OK"; else echo "E2E: FAILED"; fi
exit "$fail"
