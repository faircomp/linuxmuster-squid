#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Erzeugt einen KINIT-fähigen HTTP-Keytab für eine Proxy-Instanz gegen Samba AD.
# MANUELL vom AD-Admin auf dem DC auszuführen (braucht Domänen-Admin-Rechte).
# Wird NICHT von der Control-Plane automatisch aufgerufen (ADR-009: least privilege).
#
# Der exportierte Keytab enthält den Account-Principal (kinit-fähig, für den
# LDAP-Gruppen-Helper); derselbe Schlüssel entschlüsselt HTTP/<fqdn>-Tickets, weil
# Squid mit -s GSS_C_NO_NAME arbeitet. Den Keytab dann als Secret <keytab_secret>
# in secrets_dir der Control-Plane ablegen (siehe docs/keytab-and-dns.md).
set -euo pipefail
umask 077                                    # Keytab entsteht mit 0600 (kein 0644-Fenster)

FQDN="${1:?Usage: provision-keytab.sh <proxy-fqdn> <service-account> <out.keytab>}"
ACCOUNT="${2:?service account (kinit-fähig, existierend)}"
OUT="${3:?output keytab path}"

SPN="HTTP/${FQDN}"
SAM_LDB="${SAM_LDB:-/var/lib/samba/private/sam.ldb}"

echo "== SPN ${SPN} prüfen/anhängen an ${ACCOUNT} =="
if samba-tool spn list "${ACCOUNT}" 2>/dev/null | grep -Fq "${SPN}"; then
    echo "   ${SPN} ist bereits auf ${ACCOUNT} — überspringe (idempotent)."
else
    # Duplicate-SPN früh erkennen: hängt der SPN schon auf einem ANDEREN Konto, bricht
    # Kerberos später mit KRB_AP_ERR_MODIFIED (der KDC kann nicht disambiguieren).
    if command -v ldbsearch >/dev/null 2>&1 && [ -r "${SAM_LDB}" ]; then
        OWNER=$(ldbsearch -H "${SAM_LDB}" "(servicePrincipalName=${SPN})" sAMAccountName \
            2>/dev/null | awk '/^sAMAccountName:/ {print $2}')
        if [ -n "${OWNER:-}" ]; then
            echo "FATAL: ${SPN} existiert bereits auf Konto '${OWNER}' (duplicate SPN)." >&2
            echo "       Erst dort entfernen: samba-tool spn delete ${SPN} ${OWNER}" >&2
            exit 1
        fi
    fi
    samba-tool spn add "${SPN}" "${ACCOUNT}"
fi

echo "== Keytab für ${ACCOUNT} exportieren -> ${OUT} =="
rm -f "${OUT}"                                # frischer Keytab (exportkeytab APPENDET sonst)
samba-tool domain exportkeytab "${OUT}" --principal="${ACCOUNT}"
chmod 0600 "${OUT}"

echo "== fertig. ${OUT} als Secret in secrets_dir der Control-Plane ablegen. =="
