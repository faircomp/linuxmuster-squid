#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Downloads the UT-Capitole (Toulouse) blocklists and builds the domain list
# for Squid (dstdomain / ssl::server_name) from them. Run periodically via cron/sidecar;
# afterwards it reloads Squid (squid -k reconfigure), if reachable locally.
#
# Env overrides: UT_CAPITOLE_URL, BLOCK_CATEGORIES (space-separated), BLOCKED_DOMAINS.
set -euo pipefail

URL="${UT_CAPITOLE_URL:-https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz}"
CATEGORIES="${BLOCK_CATEGORIES:-adult malware phishing dangerous_material}"
OUT="${BLOCKED_DOMAINS:-/etc/squid/lists/blocked.domains}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== blocklist-refresh: $URL =="
# No -L: prevents redirect-based HTTPS->HTTP downgrade. In production, integrity should
# additionally be verified via a checksum/signature of the UT-Capitole list.
curl -fsS "$URL" -o "$TMP/bl.tar.gz"
tar -xzf "$TMP/bl.tar.gz" -C "$TMP"
# UT-Capitole extracts to $TMP/blacklists/<category>/domains
NEW="$TMP/new.domains"
: > "$NEW"
for c in $CATEGORIES; do
  f="$TMP/blacklists/$c/domains"
  if [ -f "$f" ]; then
    echo "  + $c ($(wc -l < "$f") domains)"
    cat "$f" >> "$NEW"
  else
    echo "  ! category missing from archive: $c"
  fi
done

# Domain normalization: force a leading dot so that dstdomain / ssl::server_name
# also match subdomains (without a dot, dstdomain matches only the exact host). Strip
# comments/blank lines, dedupe + sort, then replace atomically.
grep -vE '^[[:space:]]*(#|$)' "$NEW" | sed -E 's/^\.*/./' | sort -u > "${OUT}.tmp"

# Fail-closed: a real UT-Capitole category has thousands of entries. If the new list is
# suspiciously small (empty/truncated/tampered download), do NOT replace — the old
# list stays active and we signal an error (for alerting). BLOCKLIST_MIN_LINES is adjustable.
LINES="$(wc -l < "${OUT}.tmp")"
MIN="${BLOCKLIST_MIN_LINES:-1000}"
if [ "$LINES" -lt "$MIN" ]; then
    echo "ERROR: new blocklist has only $LINES lines (< $MIN) — suspicious; keeping the old one (fail-closed)." >&2
    rm -f "${OUT}.tmp"
    exit 1
fi

mv "${OUT}.tmp" "$OUT"
echo "== $(wc -l < "$OUT") domains -> $OUT =="

# Reload Squid, if local
squid -k reconfigure 2>/dev/null || echo "(squid -k reconfigure skipped — not local)"
