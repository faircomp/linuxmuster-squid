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

echo
if [ "$fail" -eq 0 ]; then echo "E2E: ALL ASSERTIONS OK"; else echo "E2E: FAILED"; fi
exit "$fail"
