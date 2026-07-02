#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test-Aggregator für linuxmuster-squid. Siehe docs/test-strategy.md und die
# /test-Skill. Modi: lint | unit | quick (Default) | e2e | all.
# Jeder Schritt ist dependency-gated und skippt sauber, wenn eine Toolchain fehlt.
# e2e/all verweigern ohne LMNSQUID_ALLOW_REAL=1 (Schutz vor versehentlichen Läufen).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PASS=0; FAIL=0; SKIP=0
pass(){ PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail(){ FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
skip(){ SKIP=$((SKIP + 1)); printf '  [SKIP] %s (%s)\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# run_step <name> <benötigtes-tool> <kommando...>
run_step(){
  local name="$1" tool="$2"; shift 2
  if ! have "$tool"; then skip "$name" "$tool nicht installiert"; return; fi
  if "$@"; then pass "$name"; else fail "$name"; fi
}

lint(){
  echo "== lint =="
  if have ruff; then
    run_step "ruff check"  ruff ruff check .
    run_step "ruff format" ruff ruff format --check .
  else
    skip "ruff" "nicht installiert"
  fi
  if have shellcheck; then
    local sh=()
    mapfile -t sh < <(git ls-files '*.sh' 2>/dev/null)
    if [ "${#sh[@]}" -gt 0 ]; then
      run_step "shellcheck" shellcheck shellcheck "${sh[@]}"
    else
      skip "shellcheck" "keine .sh-Dateien"
    fi
  else
    skip "shellcheck" "nicht installiert"
  fi
}

unit(){
  echo "== unit =="
  if [ -d controlplane ] || [ -d cli ]; then
    run_step "mypy" mypy mypy .
  else
    skip "mypy" "noch kein Python-Code"
  fi
  if git ls-files 'tests/*.py' '**/test_*.py' 2>/dev/null | grep -q .; then
    run_step "pytest" pytest pytest -q
  else
    skip "pytest" "noch keine Tests"
  fi
}

e2e(){
  echo "== e2e (heavy tier) =="
  if [ "${LMNSQUID_ALLOW_REAL:-0}" != "1" ]; then
    skip "kerberos-e2e" "LMNSQUID_ALLOW_REAL!=1"
    return
  fi
  if ! have docker; then skip "kerberos-e2e" "docker nicht installiert"; return; fi
  if [ -x scripts/tests/e2e_kerberos.sh ]; then
    run_step "kerberos-e2e" docker bash scripts/tests/e2e_kerberos.sh
  else
    skip "kerberos-e2e" "scripts/tests/e2e_kerberos.sh fehlt (kommt in P1)"
  fi
}

mode="${1:-quick}"
case "$mode" in
  lint)  lint ;;
  unit)  unit ;;
  quick) lint; unit ;;
  e2e)   e2e ;;
  all)   lint; unit; e2e ;;
  *) echo "usage: run.sh [lint|unit|quick|e2e|all]" >&2; exit 2 ;;
esac

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
