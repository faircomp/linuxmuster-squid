#!/bin/bash -p
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Test aggregator for linuxmuster-squid. See docs/test-strategy.md and the
# /test skill. Modes: lint | unit | quick (default) | e2e | all.
# Each step is dependency-gated and skips when a toolchain is missing.
# e2e/all refuse without LMNSQUID_ALLOW_REAL=1 (protection against accidental runs).
# quick and all run the lock gate first; lint and unit alone run without it, with the tools of
# .venv/bin first on PATH. It runs in the allowlisted environment of packaging/clean-env.sh, so
# its tools are those of .venv/bin (created by crabbox_bootstrap.sh) or the system's, never
# those of the caller's PATH.
# Skipped is not passed: exit 0 only when nothing failed and nothing was skipped. A run with a
# skipped step (a missing tool, e2e without LMNSQUID_ALLOW_REAL=1) ends with exit 3, a failure
# with exit 1. The last line names what failed and every step that was not checked (skipped, or
# not run because the lock gate failed). LMNSQUID_ALLOW_SKIP=1 accepts skips on purpose: exit 0,
# the last line still names them.
# First the restart under the allowlisted environment of packaging/clean-env.sh; before it only
# this assignment (POSIX mode: special builtins such as `.` win over functions) and `.` run.
# shellcheck disable=SC2034  # read by bash itself
POSIXLY_CORRECT=1
# shellcheck source=packaging/clean-env.sh
. "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/../../packaging/clean-env.sh"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0; SKIP=0; FAILED=(); SKIPPED=(); NOT_RUN=()
pass(){ PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail(){ FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  [FAIL] %s\n' "$1"; }
skip(){ SKIP=$((SKIP + 1)); SKIPPED+=("$1 ($2)"); printf '  [SKIP] %s (%s)\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }
summary(){ echo; echo "$PASS passed, $FAIL failed, $SKIP skipped"; }
join(){ local s; s="$(printf '%s; ' "$@")"; echo "${s%; }"; }
# The summary, then the last line (see the header) and the exit code.
finish(){
  local unchecked=("${SKIPPED[@]}") s
  for s in "${NOT_RUN[@]}"; do unchecked+=("$s (not run: the lock gate failed)"); done
  summary
  if [ "$FAIL" -ne 0 ]; then
    if [ "${#unchecked[@]}" -ne 0 ]; then
      echo "FAILED: $(join "${FAILED[@]}"); NOT checked: $(join "${unchecked[@]}")"
    else
      echo "FAILED: $(join "${FAILED[@]}"); every other step passed"
    fi
    exit 1
  elif [ "$SKIP" -ne 0 ] && [ "${LMNSQUID_ALLOW_SKIP:-0}" != 1 ]; then
    echo "NOT GREEN: $SKIP step(s) skipped, NOT checked: $(join "${unchecked[@]}")" \
         "(LMNSQUID_ALLOW_SKIP=1 accepts skips)"
    exit 3
  elif [ "$SKIP" -ne 0 ]; then
    echo "skips accepted (LMNSQUID_ALLOW_SKIP=1), NOT checked: $(join "${unchecked[@]}")"
  fi
  exit 0
}

# The lock gate comes first, before any tool of a venv runs (the fast tier of CI does the same):
# a lock-filled venv's bin/ may shadow the gate's tools and its .pth runs in every interpreter of
# it. The gate restarts itself under the allowlist (packaging/clean-env.sh) and is started by
# absolute path with /bin/bash -p; if it rejects a lock, nothing else runs.
gate(){  # <the steps that follow it>...
  echo "== lock gate =="
  if /bin/bash -p packaging/lock-deps.sh --gate; then
    pass "lock gate"
  else
    fail "lock gate"; echo "  the locks are not proven: no further step runs"
    NOT_RUN=("$@"); finish
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
    # the same guards as make deb: nothing the checkout's git config names runs
    mapfile -t sh < <(GIT_OPTIONAL_LOCKS=0 git --no-pager -c safe.directory="$ROOT" \
      -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$ROOT" ls-files '*.sh' 2>/dev/null)
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
  run_step "lock-gates" bash /bin/bash -p scripts/tests/lock_gates.sh
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
  quick) gate lint unit "lock gates (regression)" "blocklist smoke"
         dev_venv; lint; unit; locks; blocklist ;;
  e2e)   e2e ;;
  all)   gate lint unit "lock gates (regression)" "blocklist smoke" e2e
         dev_venv; lint; unit; locks; blocklist; e2e ;;
  *) echo "usage: run.sh [lint|unit|quick|e2e|all]" >&2; exit 2 ;;
esac

finish
