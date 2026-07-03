#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Lädt die UT-Capitole-(Toulouse-)Blocklisten und baut daraus die Domain-Liste
# für Squid (dstdomain / ssl::server_name). Periodisch per Cron/Sidecar ausführen;
# danach lädt es Squid neu (squid -k reconfigure), falls lokal erreichbar.
#
# Env-Overrides: UT_CAPITOLE_URL, BLOCK_CATEGORIES (Leerzeichen-getrennt), BLOCKED_DOMAINS.
set -euo pipefail

URL="${UT_CAPITOLE_URL:-https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz}"
CATEGORIES="${BLOCK_CATEGORIES:-adult malware phishing dangerous_material}"
OUT="${BLOCKED_DOMAINS:-/etc/squid/lists/blocked.domains}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== blocklist-refresh: $URL =="
# Kein -L: verhindert Redirect-basiertes HTTPS->HTTP-Downgrade. Integrität sollte in
# Produktion zusätzlich per Checksumme/Signatur der UT-Capitole-Liste geprüft werden.
curl -fsS "$URL" -o "$TMP/bl.tar.gz"
tar -xzf "$TMP/bl.tar.gz" -C "$TMP"
# UT-Capitole entpackt nach $TMP/blacklists/<kategorie>/domains
NEW="$TMP/new.domains"
: > "$NEW"
for c in $CATEGORIES; do
  f="$TMP/blacklists/$c/domains"
  if [ -f "$f" ]; then
    echo "  + $c ($(wc -l < "$f") Domains)"
    cat "$f" >> "$NEW"
  else
    echo "  ! Kategorie fehlt im Archiv: $c"
  fi
done

# Domain-Normalisierung: führenden Punkt erzwingen, damit dstdomain / ssl::server_name
# auch Subdomains matchen (ohne Punkt matcht dstdomain nur den exakten Host). Kommentare/
# Leerzeilen raus, dedupe + sort, dann atomar ersetzen.
grep -vE '^[[:space:]]*(#|$)' "$NEW" | sed -E 's/^\.*/./' | sort -u > "${OUT}.tmp"
mv "${OUT}.tmp" "$OUT"
echo "== $(wc -l < "$OUT") Domains -> $OUT =="

# Squid neu laden, falls lokal
squid -k reconfigure 2>/dev/null || echo "(squid -k reconfigure übersprungen — nicht lokal)"
