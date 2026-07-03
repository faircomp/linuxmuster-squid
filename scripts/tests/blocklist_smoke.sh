#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Offline-Smoke für blocklist-refresh.sh: baut ein Mini-Fixture-Archiv (kein Netz,
# via file://-URL) und prüft, dass NUR die gewählten Kategorien in der Ausgabe landen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/blacklists/adult" "$TMP/blacklists/news"
printf 'bad1.example\nbad2.example\n' > "$TMP/blacklists/adult/domains"
printf 'news1.example\n'              > "$TMP/blacklists/news/domains"
tar -czf "$TMP/bl.tar.gz" -C "$TMP" blacklists

out="$TMP/blocked.domains"
UT_CAPITOLE_URL="file://$TMP/bl.tar.gz" \
  BLOCK_CATEGORIES="adult" \
  BLOCKED_DOMAINS="$out" \
  bash "$ROOT/scripts/blocklist-refresh.sh" >/dev/null 2>&1

# adult muss drin sein, news NICHT (nur 'adult' angefordert)
if grep -qx 'bad1.example' "$out" && grep -qx 'bad2.example' "$out" && ! grep -q 'news1.example' "$out"; then
  echo "blocklist-refresh smoke: OK ($(wc -l < "$out") Domains)"
  exit 0
else
  echo "blocklist-refresh smoke: FEHLGESCHLAGEN"; cat "$out" || true
  exit 1
fi
