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

# Control-Plane-Tools aus dem venv bevorzugen (von crabbox_bootstrap angelegt)
[ -x "$ROOT/.venv/bin/ruff" ] && export PATH="$ROOT/.venv/bin:$PATH"

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
    run_step "ruff check" ruff ruff check .
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
  if [ -f controlplane/pyproject.toml ]; then
    run_step "mypy"   mypy   mypy --config-file controlplane/pyproject.toml controlplane/lmnsquid
    run_step "pytest" pytest pytest -q controlplane/tests
  else
    skip "unit" "noch kein Control-Plane-Code"
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
  # Kaputtes Image (FROM :dev) für den Auto-Rollback-Test bauen.
  if have docker; then
    sudo docker build -q -t linuxmuster-squid:broken deploy/e2e/broken-image >/dev/null 2>&1 || true
  fi
  # Control-Plane-Docker-Integration: echter DockerService legt einen Container an
  # + Update/Auto-Rollback; via sudo, da der crabbox-User evtl. nicht in der docker-Gruppe ist.
  if [ -x .venv/bin/pytest ]; then
    if sudo env LMNSQUID_DOCKER_IT=1 ./.venv/bin/pytest -q controlplane/tests/test_docker_integration.py; then
      pass "cp-docker-it"
    else
      fail "cp-docker-it"
    fi
  else
    skip "cp-docker-it" ".venv/pytest fehlt"
  fi
}

blocklist(){
  echo "== blocklist =="
  if have curl && have tar; then
    if bash scripts/tests/blocklist_smoke.sh; then pass "blocklist-refresh-smoke"; else fail "blocklist-refresh-smoke"; fi
  else
    skip "blocklist-smoke" "curl/tar fehlt"
  fi
}

mode="${1:-quick}"
case "$mode" in
  lint)  lint ;;
  unit)  unit ;;
  quick) lint; unit; blocklist ;;
  e2e)   e2e ;;
  all)   lint; unit; blocklist; e2e ;;
  *) echo "usage: run.sh [lint|unit|quick|e2e|all]" >&2; exit 2 ;;
esac

echo
echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
