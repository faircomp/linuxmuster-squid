<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Client-Vorlagen (GPO/WPAD)

Vorlagen, um Clients per **Gruppenrichtlinie** ihren Proxy zuzuweisen und stilles
Kerberos-SSO zu aktivieren. FQDNs/Subnetze an eure AD-DNS-Domain anpassen. Der
vollständige Ablauf + die Abnahme-Checkliste stehen in
[`docs/deployment-gpo.md`](../../docs/deployment-gpo.md).

> **Merksatz (verifiziert):** Die GPO steuert nur den *Default*, welchen Proxy ein
> Client nutzt. Die eigentliche **Lehrer/Schüler-Sicherheit erzwingt die AD-Gruppen-ACL
> am Proxy** — ein Schüler am Lehrer-Proxy wird trotz gültigem Ticket abgewiesen (403).

## Edge / Chrome (per GPO / GPP-Registry, per-user, gefiltert auf die Gruppe)

- **Expliziter Proxy** — Policy `ProxySettings` (REG_SZ, JSON) unter
  `HKCU\Software\Policies\Microsoft\Edge\ProxySettings` (Chrome:
  `…\Google\Chrome\ProxySettings`):
  ```json
  {"ProxyMode":"fixed_servers","ProxyServer":"proxy-teachers.linuxmuster.meineschule.de:3128","ProxyBypassList":"<local>;*.linuxmuster.meineschule.de;10.0.0.0/8"}
  ```
  Für Schüler `proxy-students.*` verwenden.
- **Stilles Kerberos-SSO** — eine Methode je FQDN wählen:
  - `AuthServerAllowlist = "proxy-teachers.linuxmuster.meineschule.de,proxy-students.linuxmuster.meineschule.de"` (umgeht die Zonen), **oder**
  - GPO *Site-to-Zone Assignment List* → Proxy-FQDN in Zone **1 (Lokales Intranet)**.
  - Hinweis: Kerberos-**Delegation** funktioniert nicht für Proxy-Auth; einfaches Negotiate schon.

## Firefox

- [`firefox-policies.json`](firefox-policies.json) (nach `policies.json` bzw. per ADMX):
  `Proxy` (Mode=manual, HTTPProxy/SSLProxy, Locked) + `Authentication.SPNEGO`
  (= `network.negotiate-auth.trusted-uris`) + `AllowProxies.SPNEGO=true`.

## WPAD/PAC (optional, Fallback)

- [`wpad.dat`](wpad.dat) — WPAD kann **nicht** nach Rolle unterscheiden (nur Subnetz/Raum);
  die Rollen-Trennung macht die Gruppen-ACL. **Kein `wpad`-PTR** (bricht Linux-SSO).

## Pro-Rolle-Zuweisung

Da die Proxy-Policy per-user (HKCU) ist, folgt sie dem angemeldeten Benutzer:
- **GPO-Security-Filtering** — je eine GPO für `<schule>-teachers` / `<schule>-students`, oder
- **GPP Item-Level-Targeting** (Reiter *Common*) auf die AD-Sicherheitsgruppe.
- Alternativ nach **Raum/PC** via Loopback-Verarbeitung (Merge) auf der Computer-OU.
