<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Client Templates (GPO/WPAD)

Templates for assigning clients their proxy via **Group Policy** and enabling
silent Kerberos SSO. Adjust the FQDNs/subnets to your AD DNS domain. The full
procedure + the acceptance checklist are in
[`docs/deployment-gpo.md`](../../docs/deployment-gpo.md).

> **Key point (verified):** The GPO only controls the *default* of which proxy a
> client uses. The actual **teacher/student security is enforced by the AD group ACL
> at the proxy** — a student at the teacher proxy is rejected despite a valid ticket (403).

## Edge / Chrome (via GPO / GPP registry, per-user, filtered to the group)

- **Explicit proxy** — policy `ProxySettings` (REG_SZ, JSON) under
  `HKCU\Software\Policies\Microsoft\Edge\ProxySettings` (Chrome:
  `…\Google\Chrome\ProxySettings`):
  ```json
  {"ProxyMode":"fixed_servers","ProxyServer":"proxy-teachers.linuxmuster.meineschule.de:3128","ProxyBypassList":"<local>;*.linuxmuster.meineschule.de;10.0.0.0/8"}
  ```
  For students use `proxy-students.*`.
- **Silent Kerberos SSO** — choose one method per FQDN:
  - `AuthServerAllowlist = "proxy-teachers.linuxmuster.meineschule.de,proxy-students.linuxmuster.meineschule.de"` (bypasses the zones), **or**
  - GPO *Site-to-Zone Assignment List* → proxy FQDN in zone **1 (Local Intranet)**.
  - Note: Kerberos **delegation** does not work for proxy auth; plain Negotiate does.

## Firefox

- [`firefox-policies.json`](firefox-policies.json) (to `policies.json` or via ADMX):
  `Proxy` (Mode=manual, HTTPProxy/SSLProxy, Locked) + `Authentication.SPNEGO`
  (= `network.negotiate-auth.trusted-uris`) + `AllowProxies.SPNEGO=true`.

## WPAD/PAC (optional, fallback)

- [`wpad.dat`](wpad.dat) — WPAD **cannot** distinguish by role (only subnet/room);
  the group ACL does the role separation. **No `wpad` PTR** (breaks Linux SSO).

## Per-role assignment

Since the proxy policy is per-user (HKCU), it follows the logged-in user:
- **GPO security filtering** — one GPO each for `<schule>-teachers` / `<schule>-students`, or
- **GPP item-level targeting** (tab *Common*) to the AD security group.
- Alternatively by **room/PC** via loopback processing (merge) on the computer OU.
