#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Listet die vorhandenen linuxmuster-Rollen-Gruppen (teachers/students, je Schule ggf.
# präfixiert) und gibt je Gruppe einen fertigen `lmnsquid create`-Skelettbefehl aus —
# damit der häufigste Fehler (falscher/vertippter --ad-group -> stiller 403) wegfällt.
#
# AUF DEM SAMBA-DC ausführen (samba-tool, rein lesend, KEIN Domänen-Join).
# Realm optional vorgeben: REALM=LINUXMUSTER.MEINESCHULE.DE ./discover-ad-facts.sh
set -uo pipefail
REALM="${REALM:-<REALM-eintragen>}"

command -v samba-tool >/dev/null 2>&1 \
    || { echo "samba-tool nicht gefunden — dieses Skript auf dem Samba-DC ausführen." >&2; exit 2; }

# Rollen-Gruppen = exakt 'teachers'/'students' (default-school) ODER '<schule>-teachers'/'-students'.
role_groups() {
    samba-tool group list 2>/dev/null \
        | grep -E '^(teachers|students)$|-(teachers|students)$' | sort -u
}

echo "== Rollen-Gruppen (Wert für --ad-group) =="
role_groups | sed 's/^/  - /'
[ -n "$(role_groups)" ] || echo "  (keine teachers/students-Gruppen gefunden — Schul-/Gruppennamen prüfen)"

echo
echo "== Vorlage: lmnsquid create je Gruppe (FQDN/Subnetz/Image/Keytab anpassen) =="
role_groups | while IFS= read -r g; do
    case "$g" in
        *-*) school="${g%-*}"; role="${g##*-}" ;;   # <schule>-<rolle>
        *)   school="default-school"; role="$g" ;;  # unpräfixiert = default-school
    esac
    echo "lmnsquid create --school ${school} --role ${role} --ad-group ${g} \\"
    echo "  --realm ${REALM} --visible-hostname proxy-${role}.<fqdn> \\"
    echo "  --image <image@sha256:...> --keytab-secret ${g}.keytab --school-subnets <subnetz>"
done
