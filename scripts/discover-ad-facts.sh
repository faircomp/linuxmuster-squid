#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Lists the AD groups an instance is bound to -- the GLOBAL role groups
# (role-teacher / role-student / role-staff, spanning every school) for --ad-group and
# the per-school internet groups (internet, <school>-internet) for --internet-group --
# and prints ready-to-use `lmnsquid create` commands for a teacher and a student proxy,
# so that the most common mistake (wrong/mistyped group -> silent 403) is eliminated.
#
# Run ON THE SAMBA-DC (samba-tool group list, read-only, NO domain join).
# Optionally specify the realm: REALM=LINUXMUSTER.MEINESCHULE.DE ./discover-ad-facts.sh
set -uo pipefail
REALM="${REALM:-<enter-REALM>}"

command -v samba-tool >/dev/null 2>&1 \
    || { echo "samba-tool not found — run this script on the Samba-DC." >&2; exit 2; }

GROUPS_ALL="$(samba-tool group list 2>/dev/null | sort -u)"
has_group() { grep -qxF -- "$1" <<< "$GROUPS_ALL"; }

# Exact names only: a suffix match (`-students`) would also catch every sophomorix
# class and project group (e.g. 5a-students), which are NOT role groups.
role_groups() { grep -Ex 'role-(teacher|student|staff)' <<< "$GROUPS_ALL"; }

# Schools from the sophomorix config tree; default-school's internet group is
# unprefixed, every other school's is <school>-internet. Fallback: name pattern.
internet_groups() {
    local s g
    if [ -d /etc/linuxmuster/sophomorix ]; then
        for s in /etc/linuxmuster/sophomorix/*/; do
            s="$(basename "$s")"
            [ "$s" = default-school ] && g=internet || g="${s}-internet"
            has_group "$g" && echo "$g"
        done
    else
        grep -Ex 'internet|[A-Za-z0-9-]+-internet' <<< "$GROUPS_ALL"
    fi
}

echo "== Global role groups (value for --ad-group; each spans ALL schools) =="
role_groups | sed 's/^/  - /'
[ -n "$(role_groups)" ] \
    || echo "  (none found — role-teacher/role-student are created by sophomorix on linuxmuster 7.x)"

echo
echo "== Internet groups (one per school, value for --internet-group; Internetsperre) =="
internet_groups | sed 's/^/  - /'
[ -n "$(internet_groups)" ] || echo "  (none found)"

INET_ARGS="$(internet_groups | sed 's/^/--internet-group /' | tr '\n' ' ')"

echo
echo "== Template: one teacher proxy (:3128) + one student proxy (:3129) for the whole domain =="
echo "   (adjust FQDN/keytab/subnet; --image defaults to the maintained pinned digest)"
if has_group role-teacher; then
    echo "lmnsquid create --school all --role teachers --ad-group role-teacher \\"
    echo "  --realm ${REALM} --visible-hostname proxy.<fqdn> \\"
    echo "  --keytab-secret proxy.keytab --http-port 3128 --school-subnets <subnet>"
fi
if has_group role-student; then
    echo "lmnsquid create --school all --role students --ad-group role-student \\"
    [ -n "$INET_ARGS" ] && echo "  ${INET_ARGS}\\"
    echo "  --realm ${REALM} --visible-hostname proxy.<fqdn> \\"
    echo "  --keytab-secret proxy.keytab --http-port 3129 --school-subnets <subnet>"
fi
