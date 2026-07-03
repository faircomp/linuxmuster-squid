#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Die vier E2E-Assertions. Wird im test-client-Container ausgeführt.
# Beweist authN vs. authZ über die HTTP-Codes: 200 / 403 / 403 / 407.
set -uo pipefail

PROXY="http://squid.example.internal:3128"
ALLOWED="http://origin.example.internal/"
BLOCKED="http://blocked.example.com/"
REALM="EXAMPLE.INTERNAL"
PW="Passw0rd!"
export KRB5CCNAME="FILE:/tmp/cc"   # kein Kernel-Keyring im unprivilegierten Container

fail=0

# check <beschreibung> <user|""> <url> <erwarteter-code>
check() {
  local desc="$1" user="$2" url="$3" exp="$4" code
  kdestroy -q 2>/dev/null || true
  if [ -n "$user" ]; then
    if ! printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1; then
      echo "  [FAIL] $desc: kinit $user fehlgeschlagen"; fail=1; return
    fi
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' \
              --proxy "$PROXY" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" = "$exp" ]; then
    echo "  [PASS] $desc ($code)"
  else
    echo "  [FAIL] $desc: erwartet $exp, bekam $code"; fail=1
  fi
}

# HTTPS-Check (self-signed origin -> -k). Erwartet exakten Code.
check_https() {
  local desc="$1" user="$2" url="$3" exp="$4" code
  kdestroy -q 2>/dev/null || true
  if [ -n "$user" ]; then
    printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1 || { echo "  [FAIL] $desc: kinit $user"; fail=1; return; }
  fi
  code=$(curl -sk -o /dev/null -w '%{http_code}' --proxy "$PROXY" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" = "$exp" ]; then echo "  [PASS] $desc ($code)"; else echo "  [FAIL] $desc: erwartet $exp, bekam $code"; fail=1; fi
}

# HTTPS blockiert -> Code darf NICHT 200 sein (CONNECT-Deny bzw. SNI-terminate).
check_https_blocked() {
  local desc="$1" user="$2" url="$3" code
  kdestroy -q 2>/dev/null || true
  printf '%s' "$PW" | kinit "$user@$REALM" >/dev/null 2>&1 || { echo "  [FAIL] $desc: kinit $user"; fail=1; return; }
  code=$(curl -sk -o /dev/null -w '%{http_code}' --proxy "$PROXY" --proxy-negotiate -U : "$url" 2>/dev/null || true)
  if [ "$code" != "200" ]; then echo "  [PASS] $desc (blockiert, code=$code)"; else echo "  [FAIL] $desc: unerwartet 200"; fail=1; fi
}

echo "== Kerberos-E2E-Assertions =="
check "Lehrer erlaubt"           teacher1 "$ALLOWED" 200
check "Schueler abgelehnt"       student1 "$ALLOWED" 403
check "Gesperrte Domain (Lehrer)" teacher1 "$BLOCKED" 403
check "Kein Ticket"              ""       "$ALLOWED" 407
check_https         "HTTPS erlaubt (Lehrer, splice)" teacher1 "https://secure.example.internal/" 200
check_https_blocked "HTTPS gesperrt (Lehrer)"        teacher1 "https://blocked.example.com/"

echo
if [ "$fail" -eq 0 ]; then echo "E2E: ALLE ASSERTIONS OK"; else echo "E2E: FEHLGESCHLAGEN"; fi
exit "$fail"
