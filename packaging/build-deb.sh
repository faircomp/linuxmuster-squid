#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Baut das linuxmuster-squid .deb mit einem hermetischen Python-venv unter
# /opt/linuxmuster-squid/venv (am Ziel-Pfad gebaut, damit die Shebangs stimmen)
# + systemd-Unit + Maintainer-Skripte. ALS ROOT ausführen. VERSION per Env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.9.0}"
case "$VERSION" in
    ""|*[!0-9A-Za-z.+~-]*) echo "invalid VERSION: '$VERSION'" >&2; exit 1 ;;
esac
VENV=/opt/linuxmuster-squid/venv
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "== venv @ $VENV =="
rm -rf "$VENV"
mkdir -p /opt/linuxmuster-squid
python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet "$ROOT/controlplane"

echo "== staging tree =="
mkdir -p "$STAGE/opt/linuxmuster-squid" "$STAGE/lib/systemd/system" "$STAGE/DEBIAN"
cp -a "$VENV" "$STAGE/opt/linuxmuster-squid/venv"
cp "$ROOT/packaging/systemd/linuxmuster-squid.service" \
   "$STAGE/lib/systemd/system/linuxmuster-squid.service"
sed "s/@VERSION@/$VERSION/" "$ROOT/packaging/debian/control" > "$STAGE/DEBIAN/control"
for f in postinst prerm postrm; do
    cp "$ROOT/packaging/debian/$f" "$STAGE/DEBIAN/$f"
    chmod 0755 "$STAGE/DEBIAN/$f"
done

OUT="$ROOT/linuxmuster-squid_${VERSION}_all.deb"
echo "== dpkg-deb -> $OUT =="
dpkg-deb --build --root-owner-group "$STAGE" "$OUT"
echo "== built $OUT =="

# Produktion: Paket + Repo signieren mit dem linuxmuster-GPG-Key, z. B.
#   dpkg-sig --sign builder -k <KEYID> "$OUT"
# und beim Einhängen in deb.linuxmuster.net (Branch lmn73) die Release-Signatur.
