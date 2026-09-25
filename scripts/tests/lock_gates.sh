#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regression test for the gates between the lock files and the shipped venv. They live in
# packaging/lock-deps.sh, and packaging/build-venv.sh runs all three in every build:
#   --lint           only the lines uv writes (offline, before pip reads a lock)
#   --check          the pins match their inputs, every pin has a target wheel, every hash is
#                    one PyPI lists for its pin (uv, PyPI)
#   --verify-freeze  the built venv is exactly the lock plus lmnsquid, every line name==version
# The lock cases start with the manipulations of the cold verification of stage A
# (linuxmusterDEV work/verification/cold-stage-a.md, F2: an indented `name @ file://...#sha256=`
# line passed radius's lock check and its .deb shipped the package) and add the ones asked for
# after it. Every crafted case must be rejected, for the reason named with it; a case that
# passes, or fails for another reason, fails this script.
#
#   bash scripts/tests/lock_gates.sh          --lint and --verify-freeze cases (offline) and the
#                                             --check cases (need uv and PyPI; without uv they
#                                             are SKIPPED, never counted as passed)
#   bash scripts/tests/lock_gates.sh --build  `make deb` in a copy of the tree per lock case: it
#                                             must stop in the lock gate, before anything is
#                                             installed into the shipped venv. Needs the
#                                             Build-Depends (CI: the build image, as root).
# LOCK_GATES_VERBOSE=1 prints the gate's own words for each rejected case.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_DEPS="$ROOT/packaging/lock-deps.sh"
CP=controlplane/requirements.lock
BL=packaging/requirements-build.lock
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0

# ok <label> <command...>: must exit 0.  rejects <label> <reason ERE> <command...>: must exit
# non-zero AND print the reason, so a case cannot pass because something unrelated broke.
# Output goes to $TMP/out.
ok() {
    local label=$1 rc
    shift
    "$@" > "$TMP/out" 2>&1; rc=$?
    if [ "$rc" = 0 ]; then
        echo "ok    $label"; PASS=$((PASS + 1))
    else
        echo "WRONG $label (expected exit 0, got $rc)"; sed 's/^/      /' "$TMP/out"; FAIL=$((FAIL + 1))
    fi
}
rejects() {
    local label=$1 reason=$2 rc
    shift 2
    "$@" > "$TMP/out" 2>&1; rc=$?
    if [ "$rc" != 0 ] && grep -Eq -- "$reason" "$TMP/out"; then
        echo "ok    $label (exit $rc)"; PASS=$((PASS + 1))
        if [ -n "${LOCK_GATES_VERBOSE:-}" ]; then grep -E -- "$reason" "$TMP/out" | head -n 3 | sed 's/^/      /'; fi
    else
        echo "WRONG $label (expected a rejection for /$reason/, got exit $rc)"
        tail -n 30 "$TMP/out" | sed 's/^/      /'; FAIL=$((FAIL + 1))
    fi
}

# --- the lock cases -------------------------------------------------------------------------
H64="$(printf 'e%.0s' $(seq 64))"
URL_LINE="    zzzevil @ file:///evil/zzzevil-1.0-py3-none-any.whl#sha256=$H64"
# six 1.17.0 as uv writes it, with the real sha256 of its wheel and sdist on PyPI: a pin that
# pip installs and the freeze gate accepts, but that nothing in pyproject.toml asks for.
SIX_PIN="six==1.17.0 \\
    --hash=sha256:4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274 \\
    --hash=sha256:ff70335d468e7eb6ec65b95b99d3a2836546063f63acc5171de367e834932a81
    # via lmnsquid"
# The first pin with exactly two hashes (a pure-Python wheel and its sdist). pip downloads
# only the wheel, so changing the sdist's hash passes pip; both hash cases must fail anyway.
PIN="$(awk '/^[a-z0-9]/ { order[++k] = $1; next } /^    --hash=/ { n[order[k]]++ }
            END { for (i = 1; i <= k; i++) if (n[order[i]] == 2) { print order[i]; exit } }' \
            "$ROOT/$CP")"
[ -n "$PIN" ] || { echo "no pin with two hashes in $CP"; exit 1; }

# case -> the gate that must stop it, and its words
declare -A STOP=(
    [indented-url]=lint [extra-index-url]=lint [hashes-removed]=lint [pin-without-hash]=lint
    [build-lock-indented-url]=lint
    [hash-changed-1]=check [hash-changed-2]=check [extra-pin]=check [build-lock-extra-pin]=check
)
declare -A WHY=(
    [lint]="lines a lock never contains"
    [hash-changed-1]="hashes PyPI does not list" [hash-changed-2]="hashes PyPI does not list"
    [extra-pin]="pins no longer match the inputs" [build-lock-extra-pin]="pins no longer match the inputs"
)
CASES=(indented-url extra-index-url hashes-removed hash-changed-1 hash-changed-2 extra-pin
       pin-without-hash build-lock-indented-url build-lock-extra-pin)
why() { if [ "${STOP[$1]}" = lint ]; then echo "${WHY[lint]}"; else echo "${WHY[$1]}"; fi; }

# apply <case> <tree>: the manipulation, in a copy of the repository
apply() {
    local c=$1 d=$2
    case "$c" in
        indented-url) printf '%s\n' "$URL_LINE" >> "$d/$CP" ;;
        extra-index-url) printf '%s\n' '--extra-index-url https://evil.example/simple' >> "$d/$CP" ;;
        hashes-removed)
            awk -v pin="$PIN" '$1 == pin { print pin; drop = 1; next }
                               drop && /^    --hash=/ { next }
                               { drop = 0; print }' "$d/$CP" > "$d/edit" && mv "$d/edit" "$d/$CP" ;;
        hash-changed-1 | hash-changed-2)
            # the last hex digit of the 1st or 2nd hash of $PIN flipped: still 64 hex digits
            awk -v pin="$PIN" -v nth="${c##*-}" '
                $1 == pin { inpin = 1; n = 0; print; next }
                inpin && /^    --hash=sha256:/ {
                    if (++n == nth) {
                        i = index($0, "sha256:") + 7 + 63; d = substr($0, i, 1)
                        $0 = substr($0, 1, i - 1) (d == "0" ? "1" : "0") substr($0, i + 1)
                    }
                    print; next
                }
                { inpin = 0; print }' "$d/$CP" > "$d/edit" && mv "$d/edit" "$d/$CP" ;;
        extra-pin) printf '%s\n' "$SIX_PIN" >> "$d/$CP" ;;
        pin-without-hash) printf '%s\n' 'six==1.17.0' >> "$d/$CP" ;;
        build-lock-indented-url) printf '%s\n' "$URL_LINE" >> "$d/$BL" ;;
        build-lock-extra-pin) printf '%s\n' "$SIX_PIN" >> "$d/$BL" ;;
        *) echo "unknown case $c" >&2; return 1 ;;
    esac
    # the manipulation must have changed the lock, or the case proves nothing
    ! cmp -s "$ROOT/$CP" "$d/$CP" || ! cmp -s "$ROOT/$BL" "$d/$BL"
}

# copy <dest>: the tracked files of the repository (what CI checks out)
copy() {
    mkdir -p "$1"
    git -c safe.directory='*' -C "$ROOT" ls-files -z | (cd "$ROOT" && xargs -0 cp --parents -a -t "$1")
}

if [ "${1:-}" = --build ]; then
    # The gate words must appear in the build log, the lint cases must stop before pip read a
    # lock, and no case may reach the shipped venv or leave a .deb.
    for c in "${CASES[@]}"; do
        d="$TMP/build-$c"
        copy "$d/src" && apply "$c" "$d/src" || { echo "WRONG build $c: could not prepare"; FAIL=$((FAIL + 1)); continue; }
        (cd "$d/src" && make deb) > "$d/log" 2>&1; rc=$?
        reached_pip=0; grep -q '^== build venv' "$d/log" && reached_pip=1
        if [ "$rc" != 0 ] && grep -Eq -- "$(why "$c")" "$d/log" && ! grep -q '^== venv @' "$d/log" \
            && [ -z "$(find "$d" -maxdepth 1 -name '*.deb' -print -quit)" ] \
            && { [ "${STOP[$c]}" = check ] || [ "$reached_pip" = 0 ]; }; then
            echo "ok    build $c: make deb exit $rc, stopped by --${STOP[$c]}"; PASS=$((PASS + 1))
            if [ -n "${LOCK_GATES_VERBOSE:-}" ]; then grep -E -- "$(why "$c")|:[0-9]+: " "$d/log" | head -n 3 | sed 's/^/      /'; fi
        else
            echo "WRONG build $c: make deb exit $rc (want: non-zero, /$(why "$c")/ in the log, stopped by --${STOP[$c]})"
            tail -n 30 "$d/log" | sed 's/^/      /'; FAIL=$((FAIL + 1))
        fi
    done
    echo "lock gates (build): $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" = 0 ]
    exit
fi

# --- --lint (offline) ---------------------------------------------------------------------
ok "lint: the committed lock files" bash "$LOCK_DEPS" --lint
for c in "${CASES[@]}"; do
    d="$TMP/lint-$c"
    copy "$d" && apply "$c" "$d" || { echo "WRONG lint $c: could not prepare"; FAIL=$((FAIL + 1)); continue; }
    if [ "${STOP[$c]}" = lint ]; then
        rejects "lint: $c" "${WHY[lint]}" bash "$d/packaging/lock-deps.sh" --lint
    else
        # grammatically a lock uv could have written: only --check can tell (below)
        ok "lint: $c is well-formed, left to --check" bash "$d/packaging/lock-deps.sh" --lint
    fi
done
for line in "evil==1.0 --hash=sha256:$H64" "-r /tmp/evil.txt" "--find-links /tmp/evil" \
            "-e /tmp/evil" "Evil==1.0 \\" "    --hash=sha256:$H64"; do
    d="$TMP/lint-extra"; rm -rf "$d"; copy "$d"; printf '%s\n' "$line" >> "$d/$CP"
    rejects "lint: '$line'" "${WHY[lint]}" bash "$d/packaging/lock-deps.sh" --lint
done

# --- --verify-freeze (offline) ------------------------------------------------------------
# What `pip freeze --all` prints for a correct build: the lock's pins in pip's spelling of
# the names, plus lmnsquid.
awk '/^[a-z0-9]/ { print $1 }' "$ROOT/$CP" \
    | sed -e 's/^pyyaml==/PyYAML==/' -e 's/^typing-extensions==/typing_extensions==/' > "$TMP/freeze.good"
echo "lmnsquid==7.3.5" >> "$TMP/freeze.good"
vf() { bash "$LOCK_DEPS" --verify-freeze "$ROOT/$CP" lmnsquid==7.3.5 < "$1"; }
ok "verify-freeze: the lock plus lmnsquid, pip's spelling" vf "$TMP/freeze.good"
freeze_case() {  # <label> <reason> <file>
    rejects "verify-freeze: $1" "$2" vf "$3"
}
{ cat "$TMP/freeze.good"; echo "zzzevil @ file:///evil/zzzevil-1.0-py3-none-any.whl"; } > "$TMP/f1"
freeze_case "a direct-URL install (the cold verification's line, installed)" "not a name==version pin" "$TMP/f1"
{ cat "$TMP/freeze.good"; echo "-e /tmp/evil"; } > "$TMP/f2"
freeze_case "an editable install" "not a name==version pin" "$TMP/f2"
{ cat "$TMP/freeze.good"; echo "zzzevil==1.0"; } > "$TMP/f3"
freeze_case "an extra plain pin" "not exactly" "$TMP/f3"
grep -v '^typer==' "$TMP/freeze.good" > "$TMP/f4"
freeze_case "a locked package missing" "not exactly" "$TMP/f4"
sed 's/^typer==.*/typer==0.1.0/' "$TMP/freeze.good" > "$TMP/f5"
freeze_case "a locked package in another version" "not exactly" "$TMP/f5"
grep -v '^lmnsquid==' "$TMP/freeze.good" > "$TMP/f6"
freeze_case "lmnsquid missing" "not exactly" "$TMP/f6"
sed 's/^lmnsquid==.*/lmnsquid==0.0.1/' "$TMP/freeze.good" > "$TMP/f7"
freeze_case "lmnsquid in another version" "not exactly" "$TMP/f7"
: > "$TMP/f8"
freeze_case "an empty venv" "not a name==version pin" "$TMP/f8"
rejects "verify-freeze: an unreadable lock" "cannot read" \
    bash "$LOCK_DEPS" --verify-freeze "$TMP/no-such.lock" lmnsquid==7.3.5 < "$TMP/freeze.good"

# --- --check (uv + PyPI) ------------------------------------------------------------------
if command -v uv > /dev/null 2>&1; then
    for c in "${CASES[@]}"; do
        d="$TMP/check-$c"
        copy "$d" && apply "$c" "$d" || { echo "WRONG check $c: could not prepare"; FAIL=$((FAIL + 1)); continue; }
        rejects "check: $c" "$(why "$c")" bash "$d/packaging/lock-deps.sh" --check
    done
else
    echo "SKIP  check: uv not installed (not verified)"; SKIP=$((SKIP + 1))
fi

echo "lock gates: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
