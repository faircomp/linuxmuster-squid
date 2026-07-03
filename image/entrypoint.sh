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

# /etc/krb5.conf für den LDAP-Gruppen-Helper (GSSAPI-Bind): rdns/canonicalize=false,
# damit der ldap/-SPN aus dem literalen DC-Namen (via SRV) gebildet wird und NICHT
# per Reverse-DNS (das im Container-Netz auf falsche Namen zeigt -> SASL "Local error").
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    dns_canonicalize_hostname = false
    forwardable = true
EOF

# OpenLDAP-Client: den SASL-Host NICHT per Reverse-DNS kanonikalisieren. Sonst bildet
# libldap den ldap/-SPN aus dem (falschen) PTR-Namen des DC und der GSSAPI-Bind
# scheitert mit "Local error" — unabhängig von der krb5-rdns-Einstellung.
mkdir -p /etc/ldap
printf 'SASL_NOCANON on\n' > /etc/ldap/ldap.conf

# TLS-Bump-Infrastruktur für SNI peek/splice (KEIN MITM, CA wird NIE verteilt):
# Wegwerf-CA (nur zum Aktivieren der Bump-Maschinerie) + Cert-Cache-DB initialisieren.
if [ ! -f /etc/squid/ssl/bump.pem ]; then
    mkdir -p /etc/squid/ssl
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=linuxmuster-squid-bump" \
        -keyout /etc/squid/ssl/bump.key -out /etc/squid/ssl/bump.crt 2>/dev/null
    cat /etc/squid/ssl/bump.crt /etc/squid/ssl/bump.key > /etc/squid/ssl/bump.pem
    chmod 640 /etc/squid/ssl/bump.pem
    chown -R proxy:proxy /etc/squid/ssl
fi
if [ ! -d /var/spool/squid/ssl_db ]; then
    /usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB >/dev/null 2>&1 || true
    chown -R proxy:proxy /var/spool/squid/ssl_db 2>/dev/null || true
fi

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
