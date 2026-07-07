#!/bin/sh

# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

# linuxmuster-squid entrypoint. Read-only-rootfs-friendly: ALL generated files
# live under /run/lmnsquid (tmpfs). Squid runs in the foreground.
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
: "${LOG_RETENTION_DAYS:=30}"             # access-log retention in days (logrotate)
: "${ACCESS_LOG_ENABLED:=1}"              # 1=access log on, 0=off (data privacy)

# Access log on/off (data privacy): with 0, Squid logs no requests.
if [ "${ACCESS_LOG_ENABLED}" = "0" ]; then
    ACCESS_LOG_DIRECTIVE="access_log none"
else
    ACCESS_LOG_DIRECTIVE="access_log stdio:/var/log/squid/access.log squid"
fi

RUN=/run/lmnsquid
mkdir -p "${RUN}/ssl"
chown -R proxy:proxy "${RUN}"
# Writable paths (mounted as tmpfs/volume when read-only -> chown to proxy).
mkdir -p /var/log/squid /var/spool/squid
chown proxy:proxy /var/log/squid /var/spool/squid 2>/dev/null || true

# Copy the keytab to a proxy-readable path: the mounted keytab is typically 0600 and
# owned by a foreign uid; the entrypoint (root, with DAC_OVERRIDE) copies it to /run
# (proxy, 0600) so that the helpers running as 'proxy' can read it.
if [ ! -r "${KEYTAB}" ]; then
    echo "FATAL: keytab '${KEYTAB}' is missing or not readable (mount it as a secret)." >&2
    exit 1
fi
cp "${KEYTAB}" "${RUN}/keytab"
chmod 600 "${RUN}/keytab"                 # chmod BEFORE chown (root without CAP_FOWNER cannot chmod foreign-owned files)
chown proxy:proxy "${RUN}/keytab"
KEYTAB="${RUN}/keytab"

# Kerberos: helpers read the keytab via KRB5_KTNAME; FILE ccache (no kernel keyring).
# krb5.conf/ldap.conf under /run so that /etc can stay read-only.
export KRB5_KTNAME="${KEYTAB}"
export KRB5CCNAME="FILE:${RUN}/krb5cc_${INSTANCE}"
# GSSAPI replay cache into a writable path (the default /var/tmp is not writable
# on a read-only rootfs -> "Read-only file system" -> auth BH/407).
export KRB5RCACHEDIR="${RUN}"
export KRB5_CONFIG="${RUN}/krb5.conf"
export LDAPCONF="${RUN}/ldap.conf"
# envsubst substitutes only EXPORTED variables (otherwise "http_port " => FATAL).
export INSTANCE HTTP_PORT CACHE_SIZE_MB KEYTAB REALM AD_GROUP VISIBLE_HOSTNAME SCHOOL_SUBNETS
export ACCESS_LOG_DIRECTIVE

# krb5.conf: rdns/canonicalize=false so that the ldap/ SPN is built from the literal DC name
# (via SRV) and NOT via reverse DNS (-> SASL "Local error").
cat > "${KRB5_CONFIG}" <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    dns_canonicalize_hostname = false
    forwardable = true
EOF
# OpenLDAP client: do NOT canonicalize the SASL host via reverse DNS.
printf 'SASL_NOCANON on\n' > "${LDAPCONF}"

# TLS-bump infrastructure for SNI peek/splice (NO MITM, the CA is NEVER distributed).
if [ ! -f "${RUN}/ssl/bump.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=linuxmuster-squid-bump" \
        -keyout "${RUN}/ssl/bump.key" -out "${RUN}/ssl/bump.crt" 2>/dev/null
    cat "${RUN}/ssl/bump.crt" "${RUN}/ssl/bump.key" > "${RUN}/ssl/bump.pem"
    chmod 640 "${RUN}/ssl/bump.pem"
    chown -R proxy:proxy "${RUN}/ssl"
fi
if [ ! -d /var/spool/squid/ssl_db ]; then
    /usr/lib/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB >/dev/null 2>&1 || true
    chown -R proxy:proxy /var/spool/squid/ssl_db 2>/dev/null || true
fi

TEMPLATE=/etc/squid/templates/squid.conf.template
CONF="${RUN}/squid.conf"

# Only substitute OUR variables so Squid's own %-tokens survive untouched.
envsubst '${INSTANCE} ${HTTP_PORT} ${CACHE_SIZE_MB} ${KEYTAB} ${REALM} ${AD_GROUP} ${VISIBLE_HOSTNAME} ${SCHOOL_SUBNETS} ${ACCESS_LOG_DIRECTIVE}' \
    < "${TEMPLATE}" > "${CONF}"

# The blocklist file is normally mounted read-only; create an empty one only if absent.
[ -e /etc/squid/lists/blocked.domains ] || : > /etc/squid/lists/blocked.domains 2>/dev/null || true

# Validate config, then initialise cache dirs on first run.
squid -k parse -f "${CONF}"
squid -N -f "${CONF}" -z || true

# Mirror the access log to the container stdout (`docker logs` / `lmnsquid logs`) -- only
# when access logging is on. After the setuid to 'proxy', Squid cannot write /dev/stdout,
# so a tailer does it. tail -F follows across rotation; stdbuf -oL forces line buffering
# (otherwise tail block-buffers to the pipe -> lines appear late/never).
if [ "${ACCESS_LOG_ENABLED}" != "0" ]; then
    stdbuf -oL tail -F /var/log/squid/access.log 2>/dev/null &
fi

# logrotate: cache.log ALWAYS (it grows regardless of the access-log toggle -> would fill
# the volume in privacy mode otherwise), access.log only when enabled. State on the
# PERSISTENT volume so "daily" is correct across restarts. copytruncate: no squid signal
# needed, tail -F follows the truncation. Retention = deletion deadline for the access log.
{
    if [ "${ACCESS_LOG_ENABLED}" != "0" ]; then
        cat <<EOF
/var/log/squid/access.log {
    daily
    rotate ${LOG_RETENTION_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    fi
    cat <<EOF
/var/log/squid/cache.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
} > "${RUN}/logrotate.conf"
( while true; do
      logrotate -s /var/log/squid/.logrotate.state "${RUN}/logrotate.conf" 2>/dev/null || true
      sleep 3600
  done ) &

echo "linuxmuster-squid: instance='${INSTANCE}' fqdn='${VISIBLE_HOSTNAME}' group='${AD_GROUP}@${REALM}' port=${HTTP_PORT}" >&2
exec squid -N -d1 -f "${CONF}"
