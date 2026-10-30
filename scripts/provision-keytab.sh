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

# The FQDN goes into an LDAP filter and an SPN: a host name and nothing else.
if ! printf '%s' "${FQDN}" | grep -Eqx '[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+'; then
    echo "FATAL: '${FQDN}' is not a fully qualified host name." >&2
    exit 1
fi
SPN="HTTP/${FQDN}"
SHORT="${FQDN%%.*}"
SAM_LDB="${SAM_LDB:-/var/lib/samba/private/sam.ldb}"

# Conflicts, checked on every run (also when the SPN is already on the account) and before
# anything is changed or exported: the KDC must find HTTP/<fqdn> on exactly one account.
# - HTTP/<fqdn> on another account: duplicate SPN (KRB_AP_ERR_MODIFIED).
# - host/<fqdn> or host/<short> on another account: Samba (like AD) treats host/ as an alias
#   of HTTP/ via sPNMappings, so that account answers for HTTP/<fqdn> too. `samba-tool spn
#   add` only logs check_spn_alias_collision and adds the SPN anyway. Typical cause: the
#   proxy host listed in devices.csv with a role that gets a computer account.
# ldbsearch (ldb-tools) is a dependency of linuxmuster-base7 and sophomorix4: without it, or
# without read access to sam.ldb, the check cannot run and nothing is exported.
if ! command -v ldbsearch >/dev/null 2>&1 || [ ! -r "${SAM_LDB}" ]; then
    echo "FATAL: cannot check for conflicting SPNs: ldbsearch missing or ${SAM_LDB} not readable" >&2
    echo "       (run this on the DC as root; ldbsearch is in the ldb-tools package)." >&2
    exit 1
fi
account_lc=$(printf '%s' "${ACCOUNT%\$}" | tr '[:upper:]' '[:lower:]')
conflict=0
echo "== check ${SPN}, host/${FQDN}, host/${SHORT} on other accounts =="
for spn in "${SPN}" "host/${FQDN}" "host/${SHORT}"; do
    owners=$(ldbsearch -H "${SAM_LDB}" "(servicePrincipalName=${spn})" sAMAccountName \
        2>/dev/null | awk '/^sAMAccountName:/ {print $2}')
    for owner in ${owners}; do
        owner_lc=$(printf '%s' "${owner%\$}" | tr '[:upper:]' '[:lower:]')
        [ "${owner_lc}" = "${account_lc}" ] && continue
        conflict=1
        if [ "${spn}" = "${SPN}" ]; then
            echo "FATAL: ${SPN} already exists on account '${owner}' (duplicate SPN)." >&2
            echo "       Remove it there first: samba-tool spn delete ${SPN} ${owner}" >&2
        else
            echo "FATAL: ${spn} is on account '${owner}'; host/ is an alias of HTTP/, so that" >&2
            echo "       account would get the tickets for ${SPN}." >&2
            case "${owner}" in
                *\$) echo "       '${owner}' is a computer account: if it comes from devices.csv, set the" >&2
                     echo "       role (9th column) of '${SHORT}' to iponly and run linuxmuster-import-devices" >&2
                     echo "       (no computer account, A/PTR stay); otherwise remove the account." >&2 ;;
                *)   echo "       Remove it there first: samba-tool spn delete ${spn} ${owner}" >&2 ;;
            esac
        fi
    done
done
if [ "${conflict}" -ne 0 ]; then
    echo "       Nothing was changed and no keytab was exported." >&2
    exit 1
fi

echo "== check/append SPN ${SPN} to ${ACCOUNT} =="
if samba-tool spn list "${ACCOUNT}" 2>/dev/null | grep -Fq "${SPN}"; then
    echo "   ${SPN} is already on ${ACCOUNT} — skipping (idempotent)."
else
    samba-tool spn add "${SPN}" "${ACCOUNT}"
fi

echo "== export keytab for ${ACCOUNT} -> ${OUT} =="
rm -f "${OUT}"                                # fresh keytab (exportkeytab APPENDS otherwise)
samba-tool domain exportkeytab "${OUT}" --principal="${ACCOUNT}"
chmod 0600 "${OUT}"

echo "== done. Place ${OUT} as secret in the control plane's secrets_dir. =="
