#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates a KINIT-capable HTTP keytab for a proxy instance against Samba AD.
# To be run MANUALLY by the AD admin on the DC (requires domain-admin privileges).
# Is NOT called automatically by the control plane (ADR-009: least privilege).
#
# The exported keytab contains the account principal (kinit-capable, for the
# LDAP group helper); the same key decrypts HTTP/<fqdn> tickets, because
# Squid works with -s GSS_C_NO_NAME. Then place the keytab as secret <keytab_secret>
# in the control plane's secrets_dir (see docs/keytab-and-dns.md).
set -euo pipefail
umask 077                                    # Keytab is created with 0600 (no 0644 window)

FQDN="${1:?Usage: provision-keytab.sh <proxy-fqdn> <service-account> <out.keytab>}"
ACCOUNT="${2:?service account (kinit-capable, existing)}"
OUT="${3:?output keytab path}"

SPN="HTTP/${FQDN}"
SAM_LDB="${SAM_LDB:-/var/lib/samba/private/sam.ldb}"

echo "== check/append SPN ${SPN} to ${ACCOUNT} =="
if samba-tool spn list "${ACCOUNT}" 2>/dev/null | grep -Fq "${SPN}"; then
    echo "   ${SPN} is already on ${ACCOUNT} — skipping (idempotent)."
else
    # Detect duplicate SPN early: if the SPN is already on a DIFFERENT account, Kerberos
    # breaks later with KRB_AP_ERR_MODIFIED (the KDC cannot disambiguate).
    if command -v ldbsearch >/dev/null 2>&1 && [ -r "${SAM_LDB}" ]; then
        OWNER=$(ldbsearch -H "${SAM_LDB}" "(servicePrincipalName=${SPN})" sAMAccountName \
            2>/dev/null | awk '/^sAMAccountName:/ {print $2}')
        if [ -n "${OWNER:-}" ]; then
            echo "FATAL: ${SPN} already exists on account '${OWNER}' (duplicate SPN)." >&2
            echo "       Remove it there first: samba-tool spn delete ${SPN} ${OWNER}" >&2
            exit 1
        fi
    fi
    samba-tool spn add "${SPN}" "${ACCOUNT}"
fi

echo "== export keytab for ${ACCOUNT} -> ${OUT} =="
rm -f "${OUT}"                                # fresh keytab (exportkeytab APPENDS otherwise)
samba-tool domain exportkeytab "${OUT}" --principal="${ACCOUNT}"
chmod 0600 "${OUT}"

echo "== done. Place ${OUT} as secret in the control plane's secrets_dir. =="
