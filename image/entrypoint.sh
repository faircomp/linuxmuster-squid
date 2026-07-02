#!/bin/sh
# linuxmuster-squid entrypoint: render per-instance squid.conf from the template
# and run Squid in the foreground (so `docker logs` captures access/cache logs).
set -eu

# ---- required per-instance configuration ----
: "${VISIBLE_HOSTNAME:?VISIBLE_HOSTNAME (proxy FQDN, MUST match the Kerberos SPN) is required}"
: "${REALM:?REALM (UPPERCASE AD DNS domain, e.g. LINUXMUSTER.MEINESCHULE.DE) is required}"
: "${AD_GROUP:?AD_GROUP (e.g. teachers or <school>-teachers) is required}"

# ---- optional, with sane defaults ----
: "${INSTANCE:=squid}"
: "${HTTP_PORT:=3128}"
: "${CACHE_SIZE_MB:=1000}"
: "${KEYTAB:=/run/secrets/squid_keytab}"
: "${SCHOOL_SUBNETS:=0.0.0.0/0}"          # school is identified by source subnet(s)

# The Kerberos SSO helper AND the group-ACL helper both read the keytab via
# KRB5_KTNAME. Use a file credential cache — the kernel-keyring ccache fails
# in unprivileged containers.
export KRB5_KTNAME="${KEYTAB}"
export KRB5CCNAME="FILE:/tmp/krb5cc_${INSTANCE}"

# envsubst ersetzt nur EXPORTIERTE Variablen. Defaults wie HTTP_PORT stehen sonst
# nicht in der Umgebung → leere Substitution ("http_port " => FATAL). Daher alle
# Template-Variablen explizit exportieren.
export INSTANCE HTTP_PORT CACHE_SIZE_MB KEYTAB REALM AD_GROUP VISIBLE_HOSTNAME SCHOOL_SUBNETS

if [ ! -r "${KEYTAB}" ]; then
    echo "FATAL: keytab '${KEYTAB}' is missing or not readable (mount it as a secret)." >&2
    exit 1
fi

TEMPLATE=/etc/squid/templates/squid.conf.template
CONF=/etc/squid/squid.conf

# Only substitute OUR variables so Squid's own %-tokens survive untouched.
envsubst '${INSTANCE} ${HTTP_PORT} ${CACHE_SIZE_MB} ${KEYTAB} ${REALM} ${AD_GROUP} ${VISIBLE_HOSTNAME} ${SCHOOL_SUBNETS}' \
    < "${TEMPLATE}" > "${CONF}"

# The blocklist file is normally mounted read-only; create an empty one only if absent.
[ -e /etc/squid/lists/blocked.domains ] || : > /etc/squid/lists/blocked.domains

# Validate config, then initialise cache dirs on first run.
squid -k parse -f "${CONF}"
squid -N -f "${CONF}" -z || true

echo "linuxmuster-squid: instance='${INSTANCE}' fqdn='${VISIBLE_HOSTNAME}' group='${AD_GROUP}@${REALM}' port=${HTTP_PORT}" >&2
exec squid -N -d1 -f "${CONF}"
