<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Production Deployment: Client Control via GPO & Acceptance

Goal: teachers and students get their proxy via **Group Policy** with silent
Kerberos SSO — and it works. Templates: [`deploy/clients/`](../deploy/clients/).

**Security model (verified):** The GPO only defines *which* proxy a client uses; the
**role is enforced by the AD group ACL at the proxy** (`ext_kerberos_ldap_group_acl`) —
server-side, **crabbox-verified** in the E2E (teacher 200 / student 403 / cross-access 403,
plus HTTPS splice, multischool, and the internet gate). A student on the teacher proxy is
rejected by group.

**Multi-school & visitors:** bind the proxy ACL to the **global role groups**
`role-teacher` / `role-student` (both span *all* schools) — **not** the per-school
`<school>-teachers`. Then a visitor from another school is accepted at the **local** proxy,
while teacher/student separation still holds. To keep the linuxmuster *Internetsperre*
working everywhere (incl. visitors), list **one `internet` group per school**
(`--internet-group internet --internet-group <school>-internet`): a user passes if in
**any** of them, so removing them from their home `internet` group blocks them at any
location within the short ACL TTL (~30 s). Both are crabbox-verified.

## Recipe (School Admin)

1. **Proxies:** the simplest model is **one teacher proxy + one student proxy** for the whole
   domain (one FQDN, a port per role, e.g. `:3128` / `:3129`) with `--ad-group role-teacher` /
   `role-student`. Give the FQDN a DNS A record + `HTTP/<fqdn>` SPN + keytab
   (see [`keytab-and-dns.md`](keytab-and-dns.md)); **no `wpad` PTR**.
2. **Assign the proxy per role via a *user* GPO:**
   - Edge/Chrome: `ProxySettings = {ProxyMode: fixed_servers, ProxyServer:
     proxy.<domain>:3128, ProxyBypassList: <local>;internal hosts}` (teachers; `:3129` for students).
   - Firefox: [`firefox-policies.json`](../deploy/clients/firefox-policies.json).
3. Enable **silent SSO** (one method per FQDN): `AuthServerAllowlist` = the proxy FQDN,
   **or** *Site-to-Zone* → Local Intranet. Firefox: `Authentication.SPNEGO`.
4. **Filter by role:** on the GPO, replace *Authenticated Users* under **Security Filtering**
   with **`role-teacher`** (and `role-student` for the student GPO), then **link at `OU=SCHOOLS`**
   (where the users live). User GPOs *follow the user*, so a visitor at any school gets the
   right proxy — **no loopback needed**. *(Only if schools must filter differently: keep
   per-school×role instances and link the proxy GPO to each school's room/computer OU with
   **loopback merge** so the location picks the school.)*
5. **Bypass list** (LDAP/LINBO/WebUI/internal services) in every proxy config. `--school-subnets`
   may be generous (e.g. `10.0.0.0/8`) — the group ACL is the real gate; the subnet is only
   defense-in-depth.
6. **Internetsperre:** add `--internet-group internet --internet-group <school>-internet`
   (one per school) to the instances that should honour it (usually students). Removing a user
   from their `internet` group blocks their new requests within ~30 s, at any location.
7. **Force proxy** on the OPNsense (block direct 80/443 **TCP** egress), otherwise clients
   bypass the non-inline proxy. **Additionally block UDP 443** (see Filter Limits).
8. **Exam mode:** `<user>-exam` is in no role group → the proxy denies it anyway; lmn7
   additionally disables the proxy in exam mode.

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
> The **server-side equivalent is crabbox-verified** in the E2E (13/13, incl. the internet
> gate: OR across schools, fail-closed, and removal → ~30 s → 403).

Log per client (browser, codes):

- [ ] Logged-in **teacher** → teacher proxy delivers internet, **no** login popup (SSO).
- [ ] Logged-in **student** → student proxy delivers (filtered) internet.
- [ ] **Student** manually enters the **teacher proxy** → **403** (role ACL applies).
- [ ] **Visitor** (teacher/student from **another school**) → the **local** proxy works (global role group).
- [ ] **Internetsperre:** remove a user from their `internet` group → within ~30 s → **403**.
- [ ] Blocked domain (teacher/student) → blocked.
- [ ] `Squid access.log` shows the Kerberos username + ACL verdict.

Document the result (client/browser/codes) here or in the ticket. Only then is
P8 considered accepted for production.
