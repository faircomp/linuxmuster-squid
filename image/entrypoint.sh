#!/bin/sh
# linuxmuster-squid entrypoint. Read-only-rootfs-freundlich: ALLE generierten Dateien
# liegen unter /run/lmnsquid (tmpfs). Squid läuft im Vordergrund.
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
: "${LOG_RETENTION_DAYS:=30}"             # Access-Log-Aufbewahrung in Tagen (logrotate)
: "${ACCESS_LOG_ENABLED:=1}"              # 1=Access-Log an, 0=aus (Datenschutz)

# Access-Log an/aus (Datenschutz): bei 0 protokolliert Squid keine Requests.
if [ "${ACCESS_LOG_ENABLED}" = "0" ]; then
    ACCESS_LOG_DIRECTIVE="access_log none"
else
    ACCESS_LOG_DIRECTIVE="access_log stdio:/var/log/squid/access.log squid"
fi

RUN=/run/lmnsquid
mkdir -p "${RUN}/ssl"
chown -R proxy:proxy "${RUN}"
# Schreibbare Pfade (bei read-only als tmpfs/Volume gemountet -> für proxy chownen).
mkdir -p /var/log/squid /var/spool/squid
chown proxy:proxy /var/log/squid /var/spool/squid 2>/dev/null || true

# Keytab in einen proxy-lesbaren Pfad kopieren: der gemountete Keytab ist typ. 0600 und
# gehört einem fremden uid; der Entrypoint (root, mit DAC_OVERRIDE) kopiert ihn nach /run
# (proxy, 0600), damit die als 'proxy' laufenden Helfer ihn lesen können.
if [ ! -r "${KEYTAB}" ]; then
    echo "FATAL: keytab '${KEYTAB}' is missing or not readable (mount it as a secret)." >&2
    exit 1
fi
cp "${KEYTAB}" "${RUN}/keytab"
chmod 600 "${RUN}/keytab"                 # chmod VOR chown (root ohne CAP_FOWNER kann fremd-owned nicht chmodden)
chown proxy:proxy "${RUN}/keytab"
KEYTAB="${RUN}/keytab"

# Kerberos: Helfer lesen den Keytab via KRB5_KTNAME; FILE-ccache (kein Kernel-Keyring).
# krb5.conf/ldap.conf unter /run, damit /etc read-only bleiben kann.
export KRB5_KTNAME="${KEYTAB}"
export KRB5CCNAME="FILE:${RUN}/krb5cc_${INSTANCE}"
# GSSAPI-Replay-Cache in einen schreibbaren Pfad (Default /var/tmp ist bei
# read-only-Rootfs nicht beschreibbar -> "Read-only file system" -> Auth BH/407).
export KRB5RCACHEDIR="${RUN}"
export KRB5_CONFIG="${RUN}/krb5.conf"
export LDAPCONF="${RUN}/ldap.conf"
# envsubst ersetzt nur EXPORTIERTE Variablen (sonst "http_port " => FATAL).
export INSTANCE HTTP_PORT CACHE_SIZE_MB KEYTAB REALM AD_GROUP VISIBLE_HOSTNAME SCHOOL_SUBNETS
export ACCESS_LOG_DIRECTIVE

# krb5.conf: rdns/canonicalize=false, damit der ldap/-SPN aus dem literalen DC-Namen
# (via SRV) gebildet wird und NICHT per Reverse-DNS (-> SASL "Local error").
cat > "${KRB5_CONFIG}" <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    dns_canonicalize_hostname = false
    forwardable = true
EOF
# OpenLDAP-Client: SASL-Host NICHT per Reverse-DNS kanonikalisieren.
printf 'SASL_NOCANON on\n' > "${LDAPCONF}"

# TLS-Bump-Infrastruktur für SNI peek/splice (KEIN MITM, CA wird NIE verteilt).
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

if [ "${ACCESS_LOG_ENABLED}" != "0" ]; then
    # Access-Log auf Container-stdout spiegeln, damit `docker logs` / `lmnsquid logs` ihn zeigen.
    # Squid kann nach dem setuid auf 'proxy' nicht auf /dev/stdout schreiben (Datei + Tailer).
    # tail -F folgt über Rotation hinweg; stdbuf -oL erzwingt Zeilen-Pufferung (sonst block-
    # buffert tail auf die Pipe -> Zeilen erscheinen erst spät/nie).
    stdbuf -oL tail -F /var/log/squid/access.log 2>/dev/null &

    # logrotate: access.log/cache.log täglich bzw. wöchentlich rotieren + gzip, LOG_RETENTION_DAYS
    # behalten. State-Datei auf dem PERSISTENTEN Volume, damit "daily" auch über Neustarts stimmt.
    # copytruncate: kein squid-Signal nötig, tail -F folgt der Truncation. Retention = Löschfrist.
    cat > "${RUN}/logrotate.conf" <<EOF
/var/log/squid/access.log {
    daily
    rotate ${LOG_RETENTION_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
/var/log/squid/cache.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    ( while true; do
          logrotate -s /var/log/squid/.logrotate.state "${RUN}/logrotate.conf" 2>/dev/null || true
          sleep 3600
      done ) &
fi

echo "linuxmuster-squid: instance='${INSTANCE}' fqdn='${VISIBLE_HOSTNAME}' group='${AD_GROUP}@${REALM}' port=${HTTP_PORT}" >&2
exec squid -N -d1 -f "${CONF}"
