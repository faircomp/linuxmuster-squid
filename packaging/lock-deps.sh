#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compiles the hash-pinned lock files packaging/build-venv.sh installs from:
#   controlplane/requirements.lock      <- controlplane/pyproject.toml + packaging/requirements-venv.in
#   packaging/requirements-build.lock   <- packaging/requirements-build.in
#
#   bash packaging/lock-deps.sh            re-resolve after an input changed; every pin that
#                                          still fits is kept (what Renovate does for a bump)
#   bash packaging/lock-deps.sh --upgrade  resolve from scratch (what Renovate's weekly refresh does)
#   bash packaging/lock-deps.sh --check    gate of the fast tier AND of every build, see below
#   bash packaging/lock-deps.sh --lint     only the grammar of both locks: offline, no uv
#   pip freeze --all | bash packaging/lock-deps.sh --verify-freeze <lock> <own name==version>
#                                          build gate: the venv is exactly <lock> plus the own
#                                          package, and every line of it is name==version
#
# uv writes the command into each lock's header and Renovate's pip-compile manager re-runs
# exactly that header, so keep the `--opt=value` form and only options Renovate accepts (it
# rejects --python-platform, --only-binary and --no-config; the config is switched off through
# the environment). --exclude-newer=P7D: nothing uploaded in the last 7 days is picked, the
# window in which a compromised release usually is still unnoticed. Needs uv (the one
# packaging/requirements-build.lock pins: the build and the fast tier install it from there)
# and a linux/x86_64 host: markers are evaluated for the host, the Python version is forced to
# the target's 3.12 (Ubuntu 24.04). --lint and --verify-freeze need neither uv nor network.
# uv copies the hashes of an existing output file over without fetching them again, so every
# compile here starts from an empty file or from bare pins, never from the committed lock.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export UV_NO_CONFIG=1
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCKS=(controlplane/requirements.lock packaging/requirements-build.lock)
inputs() {
    case "$1" in
        controlplane/requirements.lock) echo controlplane/pyproject.toml packaging/requirements-venv.in ;;
        packaging/requirements-build.lock) echo packaging/requirements-build.in ;;
    esac
}
HEADER_OPTS=(--python-version=3.12 --exclude-newer=P7D --generate-hashes)
command_for() { echo "uv pip compile $(inputs "$1") ${HEADER_OPTS[*]} --output-file=$1"; }

# Every requirement line (neither comment nor indented), whatever it looks like, so a line
# the grammar below would reject still shows up as a pin that does not match. An unreadable
# file fails (awk), it never yields an empty list.
pins() { awk '/^[^#[:space:]]/ { print $1 }' "$1" | LC_ALL=C sort; }
hashes() {
    awk '/^[^#[:space:]]/ { pin = $1 } /^ +--hash=/ { h = $1; sub(/^--hash=/, "", h); print pin, h }' "$1" \
        | LC_ALL=C sort
}

# Only the lines uv writes: two header comments, then per package `name==version \`, one or
# more `    --hash=sha256:<64 hex>` (all but the last continued) and `    # via` comments.
# pip would accept much more (a direct URL with the hash in its fragment, an upper-case name,
# options such as --index-url); none of that may enter a lock.
grammar() {
    awk '
        function bad(why) { printf "%s:%d: %s: %s\n", FILENAME, FNR, why, $0; err = 1 }
        FNR <= 2 { if ($0 !~ /^#/) bad("header must be the two uv comment lines"); next }
        /^[a-z0-9][a-z0-9-]*==[0-9][0-9A-Za-z.+!-]* \\$/ {
            if (cont) bad("requirement inside a continuation")
            cont = 1; next
        }
        /^    --hash=sha256:[0-9a-f]+( \\)?$/ {
            h = $1; sub(/^--hash=sha256:/, "", h)
            if (length(h) != 64) bad("hash is not 64 hex digits")
            if (!cont) bad("hash outside a requirement")
            if ($0 !~ / \\$/) cont = 0
            next
        }
        /^    # via( |$)/ || /^    #   [^ ]/ { if (cont) bad("comment inside a continuation"); next }
        { bad("not a line uv writes") }
        END { if (cont) bad("requirement without a closing hash line"); exit err }
    ' "$1"
}

# PEP 503 names, so pip freeze (PyYAML, typing_extensions) and uv (pyyaml, typing-extensions)
# compare equal.
normalize() { awk -F'==' '{ n = tolower($1); gsub(/[-_.]+/, "-", n); print n "==" $2 }' | LC_ALL=C sort; }

# `pip freeze --all` of the built venv on stdin: every line must be a plain name==version pin
# (a direct-URL install shows up as `name @ file://...`, an editable one as `-e ...`), and the
# pins must be exactly those of <lock> plus the own package. Every step is checked and nothing
# runs in a process substitution, so an error fails the gate instead of shortening a list.
verify_freeze() {  # <lock> <own name==version>
    local lock=$1 own=$2 freeze line odd=0 want have
    if [ ! -f "$lock" ] || [ ! -r "$lock" ]; then
        echo "verify-freeze: cannot read $lock" >&2; return 1
    fi
    freeze="$(cat)" || { echo "verify-freeze: cannot read pip freeze from stdin" >&2; return 1; }
    while IFS= read -r line; do
        if ! [[ $line =~ ^[A-Za-z0-9][A-Za-z0-9._-]*==[^[:space:]]+$ ]]; then
            echo "verify-freeze: not a name==version pin: '$line'" >&2; odd=$((odd + 1))
        fi
    done <<< "$freeze"
    if [ "$odd" != 0 ]; then
        echo "verify-freeze: the venv holds $odd line(s) that are not plain pins (above)" >&2
        return 1
    fi
    want="$(pins "$lock")" || { echo "verify-freeze: cannot read the pins of $lock" >&2; return 1; }
    want="$(printf '%s\n%s\n' "$want" "$own" | normalize)" || return 1
    have="$(printf '%s\n' "$freeze" | normalize)" || return 1
    printf '%s\n' "$want" > "$TMP/want" || return 1
    printf '%s\n' "$have" > "$TMP/have" || return 1
    if ! diff -u "$TMP/want" "$TMP/have" >&2; then
        echo "verify-freeze: the venv is not exactly $lock plus $own (-: expected, +: venv)" >&2
        return 1
    fi
    echo "verify-freeze: venv = $lock ($(($(wc -l < "$TMP/want") - 1)) pins) + $own"
}

# resolve <lock> <seed: pins|empty> <output> <uv options...>
# Compiles in a scratch copy of the inputs at their repository paths, so the header uv writes
# is the canonical command.
resolve() {
    local lock=$1 seed=$2 out=$3 dir f
    shift 3
    dir="$(mktemp -d -p "$TMP")"
    for f in $(inputs "$lock"); do
        mkdir -p "$dir/$(dirname "$f")"
        cp "$f" "$dir/$f"
    done
    mkdir -p "$dir/$(dirname "$lock")"
    if [ "$seed" = pins ]; then pins "$lock" > "$dir/$lock"; fi
    # shellcheck disable=SC2046  # the inputs are word lists by design
    (cd "$dir" && uv pip compile --quiet $(inputs "$lock") "$@" --output-file="$lock")
    cp "$dir/$lock" "$out"
}

mode="${1:-}"
case "$mode" in
    "" | --upgrade)
        seed=pins
        if [ "$mode" = --upgrade ]; then seed=empty; fi
        for lock in "${LOCKS[@]}"; do
            resolve "$lock" "$seed" "$lock" "${HEADER_OPTS[@]}"
            echo "$lock: $(pins "$lock" | wc -l) pins"
        done
        ;;
    --check)
        # 1. every line is one uv writes; 2. the header is the canonical command; 3. the pins
        # still satisfy the inputs AND the header's cutoff (a pin younger than 7 days fails);
        # 4. every pin has a wheel for the target (CPython 3.12, glibc 2.39, x86_64), since
        # build-venv.sh installs wheels only; 5. every committed hash is one PyPI lists for that
        # pin (PyPI may list more: files added later). 3 and 4 prefer the locked versions, so
        # the gate stays green as time passes and only moves when the lock or its inputs do.
        rc=0
        for lock in "${LOCKS[@]}"; do
            bad=0
            fail() { echo "::error file=$lock::$*"; bad=1; rc=1; }
            if ! grammar "$lock"; then
                fail "lines a lock never contains (see above)"
                continue
            fi
            if [ "$(sed -n 2p "$lock")" != "#    $(command_for "$lock")" ]; then
                fail "header is not: $(command_for "$lock")"
            fi
            # Lists go through files, not process substitutions: under `set -e` a failing
            # pins/hashes/resolve stops the gate here instead of handing diff an empty list.
            pins "$lock" > "$TMP/lock.pins"
            hashes "$lock" > "$TMP/lock.hashes"
            resolve "$lock" pins "$TMP/inputs.lock" "${HEADER_OPTS[@]}"
            pins "$TMP/inputs.lock" > "$TMP/inputs.pins"
            if ! diff -u "$TMP/lock.pins" "$TMP/inputs.pins"; then
                fail "pins no longer match the inputs or are younger than 7 days; run: bash packaging/lock-deps.sh"
            fi
            resolve "$lock" pins "$TMP/target.lock" "${HEADER_OPTS[@]}" \
                --python-platform=x86_64-manylinux_2_39 --only-binary=:all:
            pins "$TMP/target.lock" > "$TMP/target.pins"
            if ! diff -u "$TMP/lock.pins" "$TMP/target.pins"; then
                fail "a pinned version has no wheel for CPython 3.12 on Ubuntu 24.04 x86_64"
            fi
            hashes "$TMP/inputs.lock" > "$TMP/inputs.hashes"
            unknown="$(LC_ALL=C comm -23 "$TMP/lock.hashes" "$TMP/inputs.hashes")"
            if [ -n "$unknown" ]; then
                echo "$unknown"
                fail "hashes PyPI does not list for these pins (above)"
            fi
            if [ "$bad" = 0 ]; then
                echo "$lock: ok ($(pins "$lock" | wc -l) pins, $(hashes "$lock" | wc -l) hashes)"
            fi
        done
        exit "$rc"
        ;;
    --lint)
        shift
        if [ "$#" -eq 0 ]; then set -- "${LOCKS[@]}"; fi
        rc=0
        for lock in "$@"; do
            if ! grammar "$lock"; then
                echo "::error file=$lock::lines a lock never contains (see above)"; rc=1
            fi
        done
        if [ "$rc" = 0 ]; then echo "lint ok: $*"; fi
        exit "$rc"
        ;;
    --verify-freeze)
        if [ "$#" -ne 3 ]; then
            echo "usage: lock-deps.sh --verify-freeze <lock> <own name==version>" >&2; exit 2
        fi
        verify_freeze "$2" "$3"
        ;;
    *)
        sed -n '5,16p' "$0"
        exit 2
        ;;
esac
