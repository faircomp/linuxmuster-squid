#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Offline smoke test for blocklist-refresh.sh (no network, via file:// URL):
#  1) happy path: only the selected categories end up in the output (+ dot normalization),
#  2) fail-closed: a suspiciously small new list does NOT replace the old one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

mkdir -p "$TMP/blacklists/adult" "$TMP/blacklists/news"
printf 'bad1.example\nbad2.example\n' > "$TMP/blacklists/adult/domains"
printf 'news1.example\n'              > "$TMP/blacklists/news/domains"
tar -czf "$TMP/bl.tar.gz" -C "$TMP" blacklists
out="$TMP/blocked.domains"

echo "== Test 1: happy path (only 'adult') =="
UT_CAPITOLE_URL="file://$TMP/bl.tar.gz" BLOCK_CATEGORIES="adult" BLOCKED_DOMAINS="$out" \
    BLOCKLIST_MIN_LINES=1 bash "$ROOT/scripts/blocklist-refresh.sh" >/dev/null 2>&1
if grep -qx '.bad1.example' "$out" && grep -qx '.bad2.example' "$out" && ! grep -q 'news1.example' "$out"; then
    echo "  [PASS] adult in, news out, dot normalization"
else
    echo "  [FAIL] categories/normalization"; fail=$((fail + 1))
fi

echo "== Test 2: fail-closed (new list < floor -> keep old) =="
printf '.oldkeep.example\n.old2.example\n.old3.example\n' > "$out"   # existing (larger) list
if UT_CAPITOLE_URL="file://$TMP/bl.tar.gz" BLOCK_CATEGORIES="adult" BLOCKED_DOMAINS="$out" \
       BLOCKLIST_MIN_LINES=100 bash "$ROOT/scripts/blocklist-refresh.sh" >/dev/null 2>&1; then
    echo "  [FAIL] refresh should have failed (list < floor)"; fail=$((fail + 1))
elif grep -qx '.oldkeep.example' "$out"; then
    echo "  [PASS] old list kept (fail-closed)"
else
    echo "  [FAIL] old list was overwritten"; fail=$((fail + 1))
fi

echo "== blocklist smoke: $fail errors =="
exit "$fail"
