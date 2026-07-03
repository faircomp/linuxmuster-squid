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

echo "== SPN HTTP/${FQDN} an Account ${ACCOUNT} hängen =="
samba-tool spn add "HTTP/${FQDN}" "${ACCOUNT}"

echo "== Keytab für ${ACCOUNT} exportieren -> ${OUT} =="
rm -f "${OUT}"                                # frischer Keytab (exportkeytab APPENDET sonst)
samba-tool domain exportkeytab "${OUT}" --principal="${ACCOUNT}"
chmod 0600 "${OUT}"

echo "== fertig. ${OUT} als Secret in secrets_dir der Control-Plane ablegen. =="
