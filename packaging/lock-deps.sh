#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compiles the hash-pinned lock files packaging/build-deb.sh installs from:
#   controlplane/requirements.lock      <- controlplane/pyproject.toml + packaging/requirements-venv.in
#   packaging/requirements-build.lock   <- packaging/requirements-build.in
#
#   bash packaging/lock-deps.sh            re-resolve after an input changed; every pin that
#                                          still fits is kept (uv prefers the existing lock)
#   bash packaging/lock-deps.sh --upgrade  move every pin to the newest release
#   bash packaging/lock-deps.sh --check    CI gate: the locks still satisfy their inputs
#
# Needs uv (the version ci.yml pins) and a linux/x86_64 host: markers are evaluated for the
# host, the Python version is forced to the target's 3.12 (Ubuntu 24.04). uv writes the
# command into each lock's header and Renovate's pip-compile manager re-runs exactly that
# header, so keep the `--opt=value` form and only options Renovate accepts (it rejects
# --python-platform and --no-config; the config is switched off through the environment).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export UV_NO_CONFIG=1

LOCKS=(controlplane/requirements.lock packaging/requirements-build.lock)
inputs() {
    case "$1" in
        controlplane/requirements.lock) echo controlplane/pyproject.toml packaging/requirements-venv.in ;;
        packaging/requirements-build.lock) echo packaging/requirements-build.in ;;
    esac
}
# The header line uv writes; also what --check expects to find, so an edited header
# (another index, fewer inputs) cannot slip past the gate.
command_for() { echo "uv pip compile $(inputs "$1") --python-version=3.12 --generate-hashes --output-file=$1"; }
# name==version of every pin, the part that decides what gets installed
pins() { grep -E '^[a-z0-9]' "$1" | sed 's/ .*//'; }
# "name==version sha256:<hex>" for every hash of every pin
hashes() { awk '/^[a-z0-9]/ { pin = $1 } /--hash=/ { h = $1; sub(/.*--hash=/, "", h); print pin, h }' "$1" | LC_ALL=C sort; }

mode="${1:-}"
case "$mode" in
    "" | --upgrade)
        for lock in "${LOCKS[@]}"; do
            # shellcheck disable=SC2046  # the inputs are word lists by design
            uv pip compile --quiet ${mode:+--upgrade} $(inputs "$lock") \
                --python-version=3.12 --generate-hashes --output-file="$lock"
            echo "$lock: $(pins "$lock" | wc -l) pins"
        done
        ;;
    --check)
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        rc=0
        for lock in "${LOCKS[@]}"; do
            if [ "$(sed -n 2p "$lock")" != "#    $(command_for "$lock")" ]; then
                echo "::error file=$lock::header is not the command packaging/lock-deps.sh runs:"
                echo "  expected: #    $(command_for "$lock")"
                echo "  found:    $(sed -n 2p "$lock")"
                rc=1
                continue
            fi
            # Re-resolve into a copy (uv keeps the pins of the existing file where they
            # still fit), so a pin set that no longer satisfies pyproject.toml / the .in
            # file, a missing or a left-over package all show up as a changed pin. The
            # copy holds the bare pins only: uv carries the hashes of an existing output
            # file over, and they have to come from PyPI to be worth comparing.
            fresh="$tmp/$(basename "$lock")"
            pins "$lock" > "$fresh"
            # shellcheck disable=SC2046
            uv pip compile --quiet $(inputs "$lock") --python-version=3.12 \
                --generate-hashes --output-file="$fresh"
            if ! diff -u <(pins "$lock") <(pins "$fresh"); then
                echo "::error file=$lock::lock no longer matches its inputs; run: bash packaging/lock-deps.sh"
                rc=1
                continue
            fi
            # Every committed hash must be one PyPI lists for that pin. Files on PyPI are
            # never replaced, only added, so extra hashes on PyPI's side (new wheels for a
            # pinned version) are fine; a committed hash PyPI does not know is not.
            unknown="$(LC_ALL=C comm -23 <(hashes "$lock") <(hashes "$fresh"))"
            if [ -n "$unknown" ]; then
                echo "::error file=$lock::hashes PyPI does not list for these pins:"
                echo "$unknown"
                rc=1
            elif [ -n "$(LC_ALL=C comm -13 <(hashes "$lock") <(hashes "$fresh"))" ]; then
                echo "::notice file=$lock::pins ok; PyPI lists more files for them now (hashes only)"
            else
                echo "$lock: ok ($(pins "$lock" | wc -l) pins)"
            fi
        done
        exit "$rc"
        ;;
    *)
        sed -n '5,12p' "$0"
        exit 2
        ;;
esac
