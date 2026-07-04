<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Keytab & DNS Requirements

The proxy authenticates clients via Kerberos and needs a **keytab** for that,
containing the service principal `HTTP/<proxy-fqdn>`. Verified (P1 E2E, [ADR-007](decisions.md)):
The keytab must contain **a kinit-capable account principal** (not just the
HTTP SPN alias), because the group helper `ext_kerberos_ldap_group_acl` uses it
to authenticate to LDAP via GSSAPI. Negotiate runs with `-s GSS_C_NO_NAME` and decrypts
the `HTTP/<fqdn>` tickets using the same account key.

## Creating the keytab (by the AD admin)

**Default (ADR-009): NO domain join.** Neither the proxy host nor the containers join
the domain. The AD admin creates the keytab **once on the DC** and delivers the
file; the control plane does **not** provision it itself (least privilege).

1. **Recommended — service account + `samba-tool` on the DC (join-free, as proven in the E2E).**
   Create a kinit-capable service account (exists only as an AD object — no join), attach the
   `HTTP/<proxy-fqdn>` SPN to it, export its keytab → file into `secrets_dir`.
   See `scripts/provision-keytab.sh` (checks for duplicate SPNs, idempotent).
2. *(Alternative, only if the proxy host is a domain member anyway.)* `net ads keytab`
   or `msktutil` (with `--auto-update` against password rotation) uses the machine-account
   keytab. **Not needed** for the pure container model — and a join per instance would even
   be counterproductive (machine-account rotation makes keytabs stale).

## Handing the keytab to the instance

- Store it as a **Docker secret**: file in `secrets_dir` (default
  `/etc/linuxmuster-squid/secrets`), filename == the instance's `keytab_secret`.
  The control plane mounts it **read-only** under `/run/secrets/<keytab_secret>`
  (= `KEYTAB` in the container).
- **Permissions:** `0600` on the host, mounted read-only. The container entrypoint (as
  root, with `DAC_OVERRIDE`) copies the keytab once to `/run/lmnsquid/keytab`
  (proxy-readable, `0600`), so that Squid, running as `proxy`, can read it — the
  mounted keytab stays `0600`. **Never into the env/log.**
- **Separate per instance** — no shared keytab across schools.
- **Rotation:** `net ads` keytabs become invalid through machine-password rotation
  → `msktutil --auto-update` or re-export; re-export service-account keytabs on a
  password change. After rotation, recreate the instance (re-mount the secret) or
  `restart` it.

## KVNO & SPN pitfalls (verified)

- **Exporting the keytab multiple times is harmless** — `samba-tool domain exportkeytab` writes
  the *current* keys, changes **no** password and does **not** bump the KVNO. BUT it
  **appends to** an existing file → which is why `provision-keytab.sh` does `rm -f` before the
  export (otherwise stale KVNO entries accumulate and Squid may pick the wrong one).
- **Password reset / re-join (same name) invalidates old keytabs** — every reset
  increments the KVNO (`msDS-KeyVersionNumber`); old keytabs go stale (`KRB_AP_ERR_MODIFIED`
  or "matching key not found in keytab"). → **Re-export** the keytab and re-mount/`restart`
  the instance.
- **The same SPN on two accounts = breakage** — an SPN (`HTTP/<fqdn>`) must be
  **unique** domain-wide, otherwise the KDC cannot disambiguate (`KRB_AP_ERR_MODIFIED`, often
  NTLM fallback). `provision-keytab.sh` checks this beforehand (`ldbsearch`) and is idempotent;
  to check manually: `setspn -X` (Windows) or
  `ldbsearch -H .../sam.ldb '(servicePrincipalName=HTTP/<fqdn>)' sAMAccountName` (Samba).

## DNS & time requirements (hard)

- **A record** for every proxy FQDN (`visible_hostname`).
- **Forward + reverse DNS** OR `rdns = false` — the image already generates
  `/etc/krb5.conf` with `rdns=false` + `/etc/ldap/ldap.conf` `SASL_NOCANON on`, so that
  the `ldap/` SPN is formed from the literal DC name (not via PTR).
- **No `wpad` PTR** — breaks SSO for Firefox/Chromium on Linux.
- **NTP** in sync with the DC (Kerberos skew < 5 min).
- Clients must reach the proxy via **FQDN**, never via IP (otherwise no Kerberos).

See also: [`architecture.md`](architecture.md), [`decisions.md`](decisions.md) (ADR-007/008/009).
