#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test aggregator for linuxmuster-squid. See docs/test-strategy.md and the
# /test skill. Modes: lint | unit | quick (default) | e2e | all.
# Each step is dependency-gated and skips cleanly when a toolchain is missing.
# e2e/all refuse without LMNSQUID_ALLOW_REAL=1 (protection against accidental runs).
set -uo pipefail

# Nothing on the caller's PATH runs before the lock gate (see gate below), not even dirname.
here="${BASH_SOURCE[0]%/*}"; [ "$here" != "${BASH_SOURCE[0]}" ] || here=.
ROOT="$(cd "$here/../.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0; SKIP=0
pass(){ PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail(){ FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }
skip(){ SKIP=$((SKIP + 1)); printf '  [SKIP] %s (%s)\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }
summary(){ echo; echo "$PASS passed, $FAIL failed, $SKIP skipped"; }

# The lock gate comes first, before any tool of a venv runs (the fast tier of CI does the same):
# a lock-filled venv's bin/ may shadow the gate's tools and its .pth runs in every interpreter of
# it. The gate cleans its own environment (packaging/clean-env.sh) and is started by absolute
# path; if it rejects a lock, nothing else runs.
gate(){
  echo "== lock gate =="
  if /bin/bash packaging/lock-deps.sh --gate; then
    pass "lock gate"
  else
    fail "lock gate"; echo "  the locks are not proven: no further step runs"; summary; exit 1
  fi
}

# Only then the control-plane tools of the project venv (created by crabbox_bootstrap), if any.
dev_venv(){ if [ -x "$ROOT/.venv/bin/ruff" ]; then export PATH="$ROOT/.venv/bin:$PATH"; fi; }

# run_step <name> <required-tool> <command...>
run_step(){
  local name="$1" tool="$2"; shift 2
  if ! have "$tool"; then skip "$name" "$tool not installed"; return; fi
  if "$@"; then pass "$name"; else fail "$name"; fi
}

lint(){
  echo "== lint =="
  if have ruff; then
    run_step "ruff check" ruff ruff check .
  else
    skip "ruff" "not installed"
  fi
  if have shellcheck; then
    local sh=()
    mapfile -t sh < <(git ls-files '*.sh' 2>/dev/null)
    if [ "${#sh[@]}" -gt 0 ]; then
      # Warning level only: the info tier is noise here (SC2317 unreachable in
      # trap-cleanup helpers, SC2016 intentional envsubst SHELL-FORMAT quotes).
      run_step "shellcheck" shellcheck shellcheck --severity=warning "${sh[@]}"
    else
      skip "shellcheck" "no .sh files"
    fi
  else
    skip "shellcheck" "not installed"
  fi
}

unit(){
  echo "== unit =="
  if [ -f controlplane/pyproject.toml ]; then
    run_step "mypy"   mypy   mypy --config-file controlplane/pyproject.toml controlplane/lmnsquid
    run_step "pytest" pytest pytest -q controlplane/tests
  else
    skip "unit" "no control-plane code yet"
  fi
}

e2e(){
  echo "== e2e (heavy tier) =="
  if [ "${LMNSQUID_ALLOW_REAL:-0}" != "1" ]; then
    skip "kerberos-e2e" "LMNSQUID_ALLOW_REAL!=1"
    return
  fi
  if ! have docker; then skip "kerberos-e2e" "docker not installed"; return; fi
  if [ -x scripts/tests/e2e_kerberos.sh ]; then
    run_step "kerberos-e2e" docker bash scripts/tests/e2e_kerberos.sh
  else
    skip "kerberos-e2e" "scripts/tests/e2e_kerberos.sh missing (comes in P1)"
  fi
  # Build broken image (FROM :dev) for the auto-rollback test.
  if have docker; then
    sudo docker build -q -t linuxmuster-squid:broken deploy/e2e/broken-image >/dev/null 2>&1 || true
  fi
  # Control-plane Docker integration: real DockerService creates a container
  # + update/auto-rollback; via sudo, since the crabbox user may not be in the docker group.
  if [ -x .venv/bin/pytest ]; then
    if sudo env LMNSQUID_DOCKER_IT=1 ./.venv/bin/pytest -q controlplane/tests/test_docker_integration.py; then
      pass "cp-docker-it"
    else
      fail "cp-docker-it"
    fi
  else
    skip "cp-docker-it" ".venv/pytest missing"
  fi
}

locks(){
  echo "== lock gates (regression) =="
  # Needs PyPI and /usr/bin/python3 with venv; cleans its own environment.
  run_step "lock-gates" bash /bin/bash scripts/tests/lock_gates.sh
}

blocklist(){
  echo "== blocklist =="
  if have curl && have tar; then
    if bash scripts/tests/blocklist_smoke.sh; then pass "blocklist-refresh-smoke"; else fail "blocklist-refresh-smoke"; fi
  else
    skip "blocklist-smoke" "curl/tar missing"
  fi
}

mode="${1:-quick}"
case "$mode" in
  lint)  dev_venv; lint ;;
  unit)  dev_venv; unit ;;
  quick) gate; dev_venv; lint; unit; locks; blocklist ;;
  e2e)   e2e ;;
  all)   gate; dev_venv; lint; unit; locks; blocklist; e2e ;;
  *) echo "usage: run.sh [lint|unit|quick|e2e|all]" >&2; exit 2 ;;
esac

summary
[ "$FAIL" -eq 0 ]
