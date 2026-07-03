<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Produktiv-Deployment: Client-Steuerung per GPO & Abnahme

Ziel: Lehrer und Schüler bekommen per **Gruppenrichtlinie** ihren Proxy mit stillem
Kerberos-SSO — und es funktioniert. Vorlagen: [`deploy/clients/`](../deploy/clients/).

**Sicherheitsmodell (verifiziert):** Die GPO legt nur fest, welchen Proxy ein Client
als Default nutzt. Die **Lehrer/Schüler-Trennung erzwingt die AD-Gruppen-ACL am Proxy**
(`ext_kerberos_ldap_group_acl`) — server-seitig, im crabbox-E2E bewiesen (Lehrer 200 /
Schüler 403 / Quer-Zugriff 403). Selbst wenn ein Schüler manuell den Lehrer-Proxy
einträgt, wird er per Gruppe abgewiesen.

## Rezept (Schul-Admin)

1. **Pro Instanz** einen stabilen Proxy-FQDN + Kerberos-SPN + Keytab bereitstellen
   (siehe [`keytab-and-dns.md`](keytab-and-dns.md)); DNS-A-Record setzen; **kein `wpad`-PTR**.
2. **Expliziten Proxy per GPO** zuweisen (per-user, gefiltert auf die Gruppe):
   - Edge/Chrome: Policy `ProxySettings = {ProxyMode: fixed_servers, ProxyServer:
     proxy-<rolle>.<schule>:3128, ProxyBypassList: <local>;interne Hosts}`.
   - Firefox: [`firefox-policies.json`](../deploy/clients/firefox-policies.json).
3. **Stilles SSO** aktivieren (eine Methode je FQDN): `AuthServerAllowlist` = die
   Proxy-FQDNs, **oder** *Site-to-Zone* → Lokales Intranet. Firefox: `Authentication.SPNEGO`.
4. **Pro-Rolle** zuweisen: GPO-Security-Filtering auf `<schule>-teachers`/`-students`
   oder GPP-Item-Level-Targeting; optional Loopback für Raum-/PC-basierte Steuerung.
5. **Bypass-Liste** (LDAP/LINBO/WebUI/interne Dienste) in jede Proxy-Config; sicherstellen,
   dass die Client-Subnetze zur `SCHOOL_SUBNETS` der jeweiligen Instanz passen.
6. **Force-Proxy** auf der OPNsense (direkten 80/443-Egress blocken), sonst umgehen
   Clients den nicht-inline Proxy.
7. **Prüfungsmodus:** `<user>-exam` ist in keiner teachers/students-Gruppe → der Proxy
   verweigert ohnehin; lmn7 deaktiviert im Prüfungsmodus zusätzlich den Proxy.

## Produktiv-Abnahme (Human-Gate — auf echten Windows-Clients)

> Diese Schritte kann nur ein Mensch auf echten domänengejointen Clients ausführen.
> Das **server-seitige Äquivalent ist im crabbox-E2E bereits automatisiert bewiesen.**

Protokolliere pro Client (Browser, Codes):

- [ ] Angemeldeter **Lehrer** → Lehrer-Proxy liefert Internet, **kein** Login-Popup (SSO).
- [ ] Angemeldeter **Schüler** → Schüler-Proxy liefert (gefiltertes) Internet.
- [ ] **Schüler** trägt manuell den **Lehrer-Proxy** ein → **403** (Gruppen-ACL greift).
- [ ] Gesperrte Domain (Lehrer/Schüler) → geblockt.
- [ ] `Squid access.log` zeigt den Kerberos-Benutzernamen + ACL-Verdikt.

Ergebnis (Client/Browser/Codes) hier oder im Ticket dokumentieren. Erst danach gilt
P8 als produktiv abgenommen.
