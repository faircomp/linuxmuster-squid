<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Production Deployment: Client Control via GPO & Acceptance

Goal: teachers and students get their proxy via **Group Policy** with silent
Kerberos SSO — and it works. Templates: [`deploy/clients/`](../deploy/clients/).

**Security model (verified):** The GPO only defines which proxy a client uses
as its default. The **teacher/student separation is enforced by the AD group ACL at the proxy**
(`ext_kerberos_ldap_group_acl`) — server-side, proven in the E2E test (teacher 200 /
student 403 / cross-access 403). Even if a student manually enters the teacher proxy,
they are rejected by group.

## Recipe (School Admin)

1. **Per instance**, provide a stable proxy FQDN + Kerberos SPN + Keytab
   (see [`keytab-and-dns.md`](keytab-and-dns.md)); set a DNS A record; **no `wpad` PTR**.
2. **Assign an explicit proxy via GPO** (per-user, filtered to the group):
   - Edge/Chrome: policy `ProxySettings = {ProxyMode: fixed_servers, ProxyServer:
     proxy-<rolle>.<schule>:3128, ProxyBypassList: <local>;internal hosts}`.
   - Firefox: [`firefox-policies.json`](../deploy/clients/firefox-policies.json).
3. Enable **silent SSO** (one method per FQDN): `AuthServerAllowlist` = the
   proxy FQDNs, **or** *Site-to-Zone* → Local Intranet. Firefox: `Authentication.SPNEGO`.
4. **Assign per role**: GPO security filtering on `<schule>-teachers`/`-students`
   or GPP item-level targeting; optionally loopback for room-/PC-based control.
5. **Bypass list** (LDAP/LINBO/WebUI/internal services) in every proxy config; ensure
   that the client subnets match the `SCHOOL_SUBNETS` of the respective instance.
6. **Force proxy** on the OPNsense (block direct 80/443 **TCP** egress), otherwise clients
   bypass the non-inline proxy. **Additionally block UDP 443** (see Filter Limits).
7. **Exam mode:** `<user>-exam` is in no teachers/students group → the proxy
   denies it anyway; lmn7 additionally disables the proxy in exam mode.

## Filter Limits (ECH/QUIC/DoH) — close at the network edge

The HTTPS filter is **name-based** (SNI/CONNECT, no decryption). Three modern
techniques defeat it — the proxy alone cannot catch this, but the OPNsense can:
- **QUIC / HTTP-3** runs over **UDP 443** entirely past the TCP proxy → **block UDP 443**
  (browsers then fall back to TCP/443 through the proxy).
- **DoH** (DNS-over-HTTPS) bypasses the DNS view → block known DoH resolvers **and**
  set `use-application-dns.net` to NXDOMAIN via DNS (canary → Firefox disables DoH).
- **ECH** (Encrypted Client Hello) encrypts the SNI → the splice filter no longer sees the
  host. Adoption still low; monitor. Fully solvable only with SSL interception
  (a deliberate **non-goal**, [ADR-002](decisions.md)). Threat model: **T14**.

## Production Acceptance (human gate — on real Windows clients)

> Only a human can perform these steps on real domain-joined clients.
> The **server-side equivalent is already automatically proven in the E2E test.**

Log per client (browser, codes):

- [ ] Logged-in **teacher** → teacher proxy delivers internet, **no** login popup (SSO).
- [ ] Logged-in **student** → student proxy delivers (filtered) internet.
- [ ] **Student** manually enters the **teacher proxy** → **403** (group ACL applies).
- [ ] Blocked domain (teacher/student) → blocked.
- [ ] `Squid access.log` shows the Kerberos username + ACL verdict.

Document the result (client/browser/codes) here or in the ticket. Only then is
P8 considered accepted for production.
