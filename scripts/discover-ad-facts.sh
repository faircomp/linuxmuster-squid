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
# Run ON THE SAMBA-DC (samba-tool group list, testparm; read-only, NO domain join).
# The realm is read from the DC's own smb.conf (`realm`, the Kerberos realm its KDC serves);
# a REALM given in the environment is only compared with it:
#   REALM=LINUXMUSTER.MEINESCHULE.DE ./discover-ad-facts.sh
# PROXY_FQDN overrides the proxy host name in the commands (default proxy.<dns-domain>).
set -uo pipefail

command -v samba-tool >/dev/null 2>&1 \
    || { echo "samba-tool not found — run this script on the Samba-DC." >&2; exit 2; }

GIVEN_REALM="${REALM:-}"
DC_REALM="$(testparm -s --parameter-name=realm 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
if [ -n "$DC_REALM" ]; then
    REALM="$DC_REALM"
    if [ -n "$GIVEN_REALM" ] && [ "$GIVEN_REALM" != "$DC_REALM" ]; then
        echo "WARNING: REALM='$GIVEN_REALM' differs from the realm of this DC ('$DC_REALM');" >&2
        echo "         the commands below use '$DC_REALM' (smb.conf realm, the Kerberos realm)." >&2
    fi
elif [ -n "$GIVEN_REALM" ]; then
    REALM="$GIVEN_REALM"
    echo "WARNING: could not read the realm of this DC (testparm); using REALM='$REALM' unchecked." >&2
else
    REALM="<REALM>"
    echo "WARNING: could not read the realm of this DC (testparm) and no REALM given;" >&2
    echo "         replace <REALM> below (the AD DNS domain in UPPERCASE)." >&2
fi
if [ "$REALM" = "<REALM>" ]; then
    PROXY_FQDN="${PROXY_FQDN:-<proxy-fqdn>}"
else
    PROXY_FQDN="${PROXY_FQDN:-proxy.$(printf '%s' "$REALM" | tr '[:upper:]' '[:lower:]')}"
fi

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
echo "== Realm: ${REALM}   proxy FQDN: ${PROXY_FQDN} =="
echo "   (the FQDN needs an A record and must not be a computer account: devices.csv role iponly;"
echo "    PROXY_FQDN=<name> overrides it; --image defaults to the maintained pinned digest)"

echo
echo "== Template A: one teacher proxy (:3128) + one student proxy (:3129) for the whole domain =="
if has_group role-teacher; then
    echo "lmnsquid create --school all --role teachers --ad-group role-teacher \\"
    echo "  --realm ${REALM} --visible-hostname ${PROXY_FQDN} \\"
    echo "  --keytab-secret proxy.keytab --http-port 3128 --school-subnets <subnet>"
fi
if has_group role-student; then
    echo "lmnsquid create --school all --role students --ad-group role-student \\"
    [ -n "$INET_ARGS" ] && echo "  ${INET_ARGS}\\"
    echo "  --realm ${REALM} --visible-hostname ${PROXY_FQDN} \\"
    echo "  --keytab-secret proxy.keytab --http-port 3129 --school-subnets <subnet>"
fi

# One instance for everybody with internet access (as set up at a single-school site).
if has_group internet; then
    echo
    echo "== Template B (instead of A): one proxy (:3128) for everybody in 'internet' =="
    echo "   'internet' holds every account of the default school with internet access: per"
    echo "   sophomorix.ini teachers, students, parents, staff, extra students/course members and"
    echo "   the school admins. No teacher/student separation; other schools' users are not in it."
    echo "lmnsquid create --school all --role users --ad-group internet \\"
    echo "  ${INET_ARGS}\\"
    echo "  --realm ${REALM} --visible-hostname ${PROXY_FQDN} \\"
    echo "  --keytab-secret proxy.keytab --http-port 3128 --school-subnets <subnet>"
fi
