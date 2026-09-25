#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compiles and checks the hash-pinned lock files:
#   controlplane/requirements.lock      <- controlplane/pyproject.toml + packaging/requirements-venv.in
#                                          (the shipped venv, packaging/build-venv.sh)
#   packaging/requirements-build.lock   <- packaging/requirements-build.in (the throwaway build venv)
#   packaging/requirements-uv.lock      <- packaging/requirements-uv.in (uv alone, the gate's resolver)
#
#   bash packaging/lock-deps.sh            re-resolve after an input changed; every pin that
#                                          still fits is kept (what Renovate does for a bump)
#   bash packaging/lock-deps.sh --upgrade  resolve from scratch (what Renovate's weekly refresh does)
#   bash packaging/lock-deps.sh --gate     THE gate of the fast tier and of every build, see below
#   bash packaging/lock-deps.sh --lint     only the grammar of the locks: offline, no uv
#   pip freeze --all | bash packaging/lock-deps.sh --verify-freeze <lock> <name==version>...
#                                          after installing: the venv is exactly <lock> plus the
#                                          given packages, and every line of it is name==version
#
# uv writes the command into each lock's header and Renovate's pip-compile manager re-runs
# exactly that header, so keep the `--opt=value` form and only options Renovate accepts (it
# rejects --python-platform, --only-binary and --no-config; the config is switched off through
# the environment). --exclude-newer=P7D: nothing uploaded in the last 7 days is picked, the
# window in which a compromised release usually is still unnoticed. Needs a linux/x86_64 host:
# markers are evaluated for the host, the Python version is forced to the target's 3.12 (Ubuntu
# 24.04). --gate and a re-resolve need PyPI; --lint and --verify-freeze need neither uv nor
# network. uv copies the hashes of an existing output file over without fetching them again, so
# every compile here starts from an empty file or from bare pins, never from the committed lock.
#
# Every mode runs with a fixed PATH and without the caller's venv, PYTHON*, UV_*, PIP_*, GIT_*
# and CDPATH settings (packaging/clean-env.sh, which also names what it leaves to the caller);
# Python is /usr/bin/python3 -I, and uv is always the one of packaging/requirements-uv.lock,
# proven first and run by absolute path, with /usr/bin/python3 as its interpreter and PyPI as its
# only index.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# shellcheck source=packaging/clean-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/clean-env.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PYTHON=/usr/bin/python3
# The index the hashes and the closure are checked against. uv reads it from the environment,
# which clean-env.sh emptied, so nothing but this line decides it (the lock tests change this
# line, and only this line, in a copy of the tree to "publish" a package of their own).
PYPI_SIMPLE=https://pypi.org/simple
export UV_DEFAULT_INDEX="$PYPI_SIMPLE" UV_PYTHON="$PYTHON"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCKS=(controlplane/requirements.lock packaging/requirements-build.lock packaging/requirements-uv.lock)
TOOL_LOCK=packaging/requirements-uv.lock
inputs() {
    case "$1" in
        controlplane/requirements.lock) echo controlplane/pyproject.toml packaging/requirements-venv.in ;;
        packaging/requirements-build.lock) echo packaging/requirements-build.in ;;
        packaging/requirements-uv.lock) echo packaging/requirements-uv.in ;;
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
verify_freeze() {  # <lock> <name==version>...: the lock plus these (the own package, ensurepip's pip)
    local lock=$1 freeze line odd=0 want have
    shift
    local extra=("$@")
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
    want="$(printf '%s\n' "$want" "${extra[@]}" | normalize)" || return 1
    have="$(printf '%s\n' "$freeze" | normalize)" || return 1
    printf '%s\n' "$want" > "$TMP/want" || return 1
    printf '%s\n' "$have" > "$TMP/have" || return 1
    if ! diff -u "$TMP/want" "$TMP/have" >&2; then
        echo "verify-freeze: the venv is not exactly $lock plus ${extra[*]} (-: expected, +: venv)" >&2
        return 1
    fi
    echo "verify-freeze: venv = $lock ($(($(wc -l < "$TMP/want") - ${#extra[@]})) pins) + ${extra[*]}"
}

# The tool lock pins uv and nothing else, proven before anything of it is installed: every
# hash is one PyPI publishes for exactly that uv version, uploaded at least 7 days ago (the
# cutoff --exclude-newer=P7D applies to the other locks). Standard library only, in an isolated
# interpreter without site-packages, so nothing a lock brought in can take part.
tool_lock() {  # <lock>, after grammar()
    "$PYTHON" -I -S - "$1" <<'PY'
import datetime
import json
import re
import sys
import urllib.request

path = sys.argv[1]
pins, hashes = [], set()
for line in open(path, encoding="utf-8"):
    if m := re.match(r"^([a-z0-9][a-z0-9-]*)==(\S+) \\$", line):
        pins.append((m[1], m[2]))
    elif m := re.match(r"^    --hash=sha256:([0-9a-f]{64})", line):
        hashes.add(m[1])
if [name for name, _ in pins] != ["uv"] or not hashes:
    sys.exit(f"::error file={path}::must pin uv and nothing else, with hashes; pins: {pins}")
name, version = pins[0]
url = f"https://pypi.org/pypi/{name}/{version}/json"
# A short timeout: without network the gate fails within seconds; if PyPI hangs, here after
# 30 s, and later in uv's own requests after about 45 s per lock (uv's timeout and retries).
with urllib.request.urlopen(url, timeout=30) as r:
    published = {f["digests"]["sha256"]: f["upload_time_iso_8601"] for f in json.load(r)["urls"]}
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)
unknown = sorted(hashes - published.keys())
young = sorted(h for h in hashes & published.keys()
               if datetime.datetime.fromisoformat(published[h].replace("Z", "+00:00")) > cutoff)
for h in unknown:
    print(f"{name}=={version} sha256:{h}: not published by PyPI")
for h in young:
    print(f"{name}=={version} sha256:{h}: uploaded {published[h]}, less than 7 days ago")
if unknown or young:
    sys.exit(f"::error file={path}::uv=={version}: hashes PyPI does not list or younger than 7 days")
print(f"{path}: ok (uv=={version}, {len(hashes)} hashes PyPI publishes, all older than 7 days)")
PY
}

# resolve <lock> <seed: pins|empty> <output> <uv options...>
# Compiles in a scratch copy of the inputs at their repository paths, so the header uv writes
# is the canonical command.
resolve() {
    local lock=$1 seed=$2 out=$3 dir f
    shift 3
    # Explicit returns: --check calls this inside `if`, where `set -e` does not apply, and a
    # failed compile must not hand back the seed as if it were the result.
    dir="$(mktemp -d -p "$TMP")" || return 1
    for f in $(inputs "$lock"); do
        mkdir -p "$dir/$(dirname "$f")" && cp "$f" "$dir/$f" || return 1
    done
    mkdir -p "$dir/$(dirname "$lock")" || return 1
    if [ "$seed" = pins ]; then pins "$lock" > "$dir/$lock" || return 1; fi
    # shellcheck disable=SC2046  # the inputs are word lists by design
    (cd "$dir" && "$UV" pip compile --quiet $(inputs "$lock") "$@" --output-file="$lock") || return 1
    cp "$dir/$lock" "$out"
}

# 1. every line is one uv writes; 2. the header is the canonical command; 3. every hash is one
# the index publishes for exactly that name==version (the pins compiled alone, without their
# dependencies; the index may list more: files added later); 4. the pins are exactly the
# closure of the inputs, within the header's cutoff (a pin younger than 7 days, an extra or a
# missing package fails); 5. every pin has a wheel for the target (CPython 3.12, glibc 2.39,
# x86_64), since build-venv.sh installs wheels only. 4 and 5 prefer the locked versions, so the
# gate stays green as time passes and only moves when the lock or its inputs do.
check_locks() {
    local lock bad rc=0 unknown
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
        # pins/hashes stops the gate here instead of handing diff an empty list.
        pins "$lock" > "$TMP/lock.pins"
        hashes "$lock" > "$TMP/lock.hashes"
        rm -f "$TMP/published.lock"
        if ! (cd "$TMP" && "$UV" pip compile --quiet --no-deps lock.pins "${HEADER_OPTS[@]}" \
                --output-file=published.lock); then
            fail "a pin that the index does not publish or that is younger than 7 days (above)"
            continue
        fi
        hashes "$TMP/published.lock" > "$TMP/published.hashes"
        unknown="$(LC_ALL=C comm -23 "$TMP/lock.hashes" "$TMP/published.hashes")"
        if [ -n "$unknown" ]; then
            echo "$unknown"
            fail "hashes PyPI does not list for these pins (above)"
        fi
        if ! resolve "$lock" pins "$TMP/inputs.lock" "${HEADER_OPTS[@]}"; then
            fail "the inputs cannot be resolved with these pins (above)"
            continue
        fi
        pins "$TMP/inputs.lock" > "$TMP/inputs.pins"
        if ! diff -u "$TMP/lock.pins" "$TMP/inputs.pins"; then
            fail "pins no longer match the inputs or are younger than 7 days; run: bash packaging/lock-deps.sh"
        fi
        if ! resolve "$lock" pins "$TMP/target.lock" "${HEADER_OPTS[@]}" \
                --python-platform=x86_64-manylinux_2_39 --only-binary=:all:; then
            fail "a pinned version has no wheel for CPython 3.12 on Ubuntu 24.04 x86_64 (above)"
            continue
        fi
        pins "$TMP/target.lock" > "$TMP/target.pins"
        if ! diff -u "$TMP/lock.pins" "$TMP/target.pins"; then
            fail "a pinned version has no wheel for CPython 3.12 on Ubuntu 24.04 x86_64"
        fi
        if [ "$bad" = 0 ]; then
            echo "$lock: ok ($(pins "$lock" | wc -l) pins, $(hashes "$lock" | wc -l) hashes)"
        fi
    done
    return "$rc"
}

lint_locks() {  # <lock>...
    local lock rc=0
    for lock in "$@"; do
        if ! grammar "$lock"; then
            echo "::error file=$lock::lines a lock never contains (see above)"; rc=1
        fi
    done
    if [ "$rc" = 0 ]; then echo "lint ok: $*"; fi
    return "$rc"
}

# uv from the uv-only lock, proven before it is installed (grammar, uv alone, hashes PyPI
# publishes, older than 7 days), into a venv of its own; run only as $UV, by absolute path, and
# with a fresh cache, so nothing an earlier run left behind takes part.
proven_uv() {
    grammar "$TOOL_LOCK"
    tool_lock "$TOOL_LOCK"
    "$PYTHON" -I -m venv "$TMP/uv"
    "$TMP/uv/bin/python" -I -m pip install --quiet \
        --require-hashes --no-deps --only-binary :all: -r "$TOOL_LOCK"
    UV="$TMP/uv/bin/uv"
    export UV_CACHE_DIR="$TMP/uv-cache"
}

mode="${1:-}"
case "$mode" in
    "" | --upgrade)
        seed=pins
        if [ "$mode" = --upgrade ]; then seed=empty; fi
        proven_uv
        for lock in "${LOCKS[@]}"; do
            resolve "$lock" "$seed" "$lock" "${HEADER_OPTS[@]}"
            echo "$lock: $(pins "$lock" | wc -l) pins"
        done
        ;;
    --gate)
        # The gate of every build (packaging/build-venv.sh) and of the fast tier, run BEFORE
        # anything from a lock is installed anywhere. Nothing a lock brings in runs until all
        # locks are proven: no program or interpreter of a venv filled from a lock, and no such
        # bin/ on PATH (a wheel may ship its own diff, comm or python3, and a .pth runs in every
        # interpreter of its venv). The tools are the host's, from the fixed PATH (the pinned
        # build image, or the runner in the fast tier), /usr/bin/python3 -I, and uv from a lock
        # holding uv alone (proven_uv).
        lint_locks "${LOCKS[@]}"
        proven_uv
        check_locks
        ;;
    --lint)
        shift
        if [ "$#" -eq 0 ]; then set -- "${LOCKS[@]}"; fi
        lint_locks "$@"
        ;;
    --verify-freeze)
        if [ "$#" -lt 3 ]; then
            echo "usage: lock-deps.sh --verify-freeze <lock> <name==version>..." >&2; exit 2
        fi
        shift
        verify_freeze "$@"
        ;;
    *)
        sed -n '5,20p' "$0"
        exit 2
        ;;
esac
