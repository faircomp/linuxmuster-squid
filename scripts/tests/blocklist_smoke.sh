#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Offline-Smoke für blocklist-refresh.sh (kein Netz, via file://-URL):
#  1) happy path: nur gewählte Kategorien landen in der Ausgabe (+ Punkt-Normalisierung),
#  2) fail-closed: eine verdächtig kleine neue Liste ersetzt die alte NICHT.
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

echo "== Test 1: happy path (nur 'adult') =="
UT_CAPITOLE_URL="file://$TMP/bl.tar.gz" BLOCK_CATEGORIES="adult" BLOCKED_DOMAINS="$out" \
    BLOCKLIST_MIN_LINES=1 bash "$ROOT/scripts/blocklist-refresh.sh" >/dev/null 2>&1
if grep -qx '.bad1.example' "$out" && grep -qx '.bad2.example' "$out" && ! grep -q 'news1.example' "$out"; then
    echo "  [PASS] adult drin, news raus, Punkt-Normalisierung"
else
    echo "  [FAIL] Kategorien/Normalisierung"; fail=$((fail + 1))
fi

echo "== Test 2: fail-closed (neue Liste < Floor -> alte behalten) =="
printf '.oldkeep.example\n.old2.example\n.old3.example\n' > "$out"   # bestehende (größere) Liste
if UT_CAPITOLE_URL="file://$TMP/bl.tar.gz" BLOCK_CATEGORIES="adult" BLOCKED_DOMAINS="$out" \
       BLOCKLIST_MIN_LINES=100 bash "$ROOT/scripts/blocklist-refresh.sh" >/dev/null 2>&1; then
    echo "  [FAIL] Refresh hätte fehlschlagen müssen (Liste < Floor)"; fail=$((fail + 1))
elif grep -qx '.oldkeep.example' "$out"; then
    echo "  [PASS] alte Liste behalten (fail-closed)"
else
    echo "  [FAIL] alte Liste wurde überschrieben"; fail=$((fail + 1))
fi

echo "== blocklist smoke: $fail Fehler =="
exit "$fail"
