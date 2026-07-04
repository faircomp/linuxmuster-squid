#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Lists the existing linuxmuster role groups (teachers/students, prefixed per school where
# applicable) and prints a ready-to-use `lmnsquid create` skeleton command per group —
# so that the most common mistake (wrong/mistyped --ad-group -> silent 403) is eliminated.
#
# Run ON THE SAMBA-DC (samba-tool, read-only, NO domain join).
# Optionally specify the realm: REALM=LINUXMUSTER.MEINESCHULE.DE ./discover-ad-facts.sh
set -uo pipefail
REALM="${REALM:-<enter-REALM>}"

command -v samba-tool >/dev/null 2>&1 \
    || { echo "samba-tool not found — run this script on the Samba-DC." >&2; exit 2; }

# Role groups = exactly 'teachers'/'students' (default-school) OR '<school>-teachers'/'-students'.
role_groups() {
    samba-tool group list 2>/dev/null \
        | grep -E '^(teachers|students)$|-(teachers|students)$' | sort -u
}

echo "== Role groups (value for --ad-group) =="
role_groups | sed 's/^/  - /'
[ -n "$(role_groups)" ] || echo "  (no teachers/students groups found — check school/group names)"

echo
echo "== Template: lmnsquid create per group (adjust FQDN/subnet/image/keytab) =="
role_groups | while IFS= read -r g; do
    case "$g" in
        *-*) school="${g%-*}"; role="${g##*-}" ;;   # <school>-<role>
        *)   school="default-school"; role="$g" ;;  # unprefixed = default-school
    esac
    echo "lmnsquid create --school ${school} --role ${role} --ad-group ${g} \\"
    echo "  --realm ${REALM} --visible-hostname proxy-${role}.<fqdn> \\"
    echo "  --image <image@sha256:...> --keytab-secret ${g}.keytab --school-subnets <subnet>"
done
