<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Entscheidungen (ADRs) — linuxmuster-squid

Kurze Architecture Decision Records. Neue Entscheidung = neuer Eintrag; wird eine
Entscheidung revidiert, den alten Eintrag auf `Superseded by ADR-XXX` setzen statt
löschen. Status: `Accepted` (bestätigt) · `Assumed` (Default, noch zu bestätigen) ·
`Proposed` · `Superseded`.

---

### ADR-000 — Lizenz & SPDX
**Status:** Accepted (Default 2026-07-02; jederzeit änderbar). **Entscheidung:** `GPL-3.0-or-later`, © Kevin Stenzel; jede
Quelldatei mit REUSE/SPDX-Header. **Warum:** konsistent mit dem übrigen Stack des
Autors und dem GPL-Ökosystem von linuxmuster.net. **Offen:** vom Nutzer bestätigen
(Org/Brand: „faircomp" vs. „Admin Cave").

### ADR-001 — Expliziter Forward-Proxy, kein transparent/intercept
**Status:** Accepted (verifiziert). **Entscheidung:** Ausschließlich expliziter
Forward-Proxy. **Warum:** Squid kann im Intercept-Modus keine Proxy-Auth (HTTP 407);
Negotiate/NTLM-State hängt an der TCP-Verbindung. Benutzer-/Gruppen-Policy erfordert
zwingend explizit. **Quelle:** Squid-Wiki Features/Authentication.

### ADR-002 — HTTPS: Filtern ohne Entschlüsselung
**Status:** Accepted (Nutzerentscheidung). **Entscheidung:** SNI peek+splice bzw.
CONNECT-`dstdomain`; **kein** SSL-Bump-MITM. Peek-CA wird nie an Clients verteilt.
**Warum:** datenschutzfreundlich, kein Client-CA-Rollout, kein Bruch von
Cert-Pinning; SSL-bumpter Traffic könnte keine Kerberos-Identität mehr tragen.

### ADR-003 — Eine Instanz je (Schule × Rolle)
**Status:** Accepted (Nutzerentscheidung). **Entscheidung:** getrennte Squid-Container
je Rolle/Schule mit eigener Policy/Port/Log. **Warum:** maximale Isolation und
unterschiedliche Configs; Blast-Radius-Begrenzung.

### ADR-004 — Verwaltung über REST-API + CLI
**Status:** Accepted (Nutzerentscheidung). **Entscheidung:** eine Kern-Engine,
REST-API als Interface, CLI als dünner Client. **Warum:** kein doppelter Code, ein
auditierter Pfad; deckt Lifecycle + sicheres, digest-gepinntes Update ab.

### ADR-005 — Stack Python/FastAPI + Typer
**Status:** Accepted (Default 2026-07-02; jederzeit änderbar). **Entscheidung:** Control Plane = FastAPI/uvicorn, CLI = Typer;
Docker via **docker-py (`docker`≥7)**, nicht stdout-Parsing von `docker compose`.
**Warum:** linuxmuster-api7/webui7 sind FastAPI/Python (Ökosystem-Nähe); docker-py
liefert strukturierte Lifecycle-/Health-/Digest-APIs. **Alternative:** Go
(Einzel-Binary) — abgewogen, zurückgestellt.

### ADR-006 — Image aus `squid-openssl` (nicht `squid`)
**Status:** Accepted (verifiziert). **Entscheidung:** `squid-openssl` + `squidclient`
installieren. **Warum:** Auf Ubuntu 24.04 ist `squid` **ohne** OpenSSL gebaut →
`ssl_bump`/peek-splice unmöglich; `squid-openssl` (6.14) enthält SSL **und** alle
Kerberos/LDAP-Helfer. `squidclient` ist ein eigenes Paket; `ntlm_auth` käme aus
`winbind` (nur falls NTLM-Fallback nötig). **Quelle:** packages.ubuntu.com noble
filelists.

### ADR-007 — Autorisierung via `ext_kerberos_ldap_group_acl`
**Status:** Accepted (verifiziert). **Entscheidung:** Gruppenprüfung bevorzugt mit
`ext_kerberos_ldap_group_acl` (nutzt das Kerberos-Ticket, kein Bind-PW in der
Config, rekursive Gruppen, DC-Discovery via SRV); `ext_ldap_group_acl` als
Alternative mit explizitem Bind/GC. **Offen (P0):** `%u` vs. `%v`-Platzhalter und
exakter Gruppen-DN am realen DC verifizieren.
**Verifiziert (P1, E2E 4/4):** Der Helper funktioniert im Container nur mit
(1) Paket `libsasl2-modules-gssapi-mit`; (2) `/etc/ldap/ldap.conf` mit
`SASL_NOCANON on` — libldap kanonikalisiert den SASL-Host sonst per Reverse-DNS →
falscher `ldap/`-SPN → „Local error"; (3) `/etc/krb5.conf` mit `rdns=false`;
(4) einem **kinit-fähigen** Principal im Keytab (echter Account, nicht nur der
HTTP-SPN-Alias); (5) Negotiate `-s GSS_C_NO_NAME`. In Produktion (domänengejointer
Proxy mit Maschinenkonto-Keytab) sind (4)/(5) automatisch erfüllt.

### ADR-008 — Netzmodell: port-basiert, ein Host-Keytab (Default)
**Status:** Accepted (Default 2026-07-02; jederzeit änderbar). **Entscheidung:** Instanzen unterscheiden sich über Port +
Gruppen-Policy; ein Host-FQDN/Keytab (SPN ist portunabhängig). **Warum:**
einfachste DNS/Keytab-Pflege; jede Instanz erzwingt trotzdem ihre Gruppe.
**Alternative:** macvlan mit eigener IP/FQDN/Keytab je Instanz (max. Isolation +
Firewall-Trennung) — bei Bedarf.

### ADR-009 — Keytabs vom AD-Admin geliefert (Default)
**Status:** Accepted (Default 2026-07-02; jederzeit änderbar). **Entscheidung:** Control Plane konsumiert extern gelieferte
Keytabs (Secret-Mount). Auto-Provisionierung (`msktutil`/`samba-tool`) bleibt
**abgeschaltetes** Optional-Feature. **Warum:** weniger Rechte/Angriffsfläche,
sicherer MVP.

### ADR-010 — Updates: Digest-Pin + Renovate + Health-Rollback, kein Watchtower
**Status:** Accepted (verifiziert). **Entscheidung:** git als Source of Truth,
`image@sha256:`-Pin, Renovate (`automerge:false`, Merge = Go/No-Go), kontrolliertes
`pull`+`up` mit Health-Check-Auto-Rollback; Tooling als signiertes `.deb`.
**Warum:** Watchtower ist archiviert (2025-12-17), ohne Rollback, wendet Breaking
Changes blind an, braucht Root-Socket.

### ADR-011 — Packaging via dh-virtualenv
**Status:** Proposed. **Entscheidung:** `.deb` mit hermetischem venv zur Build-Zeit
(dh-virtualenv), **kein** pip-in-postinst. **Warum:** reproduzierbar/signierbar,
kein Netz/pip-als-root bei Installation (Verbesserung ggü. webui7/api7); Layout
sonst an linuxmuster angelehnt. **Achtung:** Build- und Ziel-Python-Minor müssen
übereinstimmen.

### ADR-012 — Docker-Socket hinter Proxy (root-äquivalent behandeln)
**Status:** Accepted (verifiziert). **Entscheidung:** API strikt an **`127.0.0.1`** +
Token; Zugriff auf den Socket via `docker-socket-proxy` (nur nötige Endpunkte) oder
rootless Docker. **Warum:** Schreibzugriff auf `docker.sock` = passwortloses Root auf
dem Host; das untergräbt sonst die systemd-Härtung.
**Ehrliche Grenze (P11.4):** Der Socket-Proxy braucht `CONTAINERS`+`VOLUMES`+`POST`, um
Instanzen zu fahren — damit kann ein kompromittierter Aufrufer einen Container **mit
Host-Bind-Mount** erzeugen = weiterhin Host-Root. Der Proxy **verkleinert die Fläche,
downgradet aber nicht unter Root**; die echte Antwort ist **rootless Docker**. Zudem
lauscht der Proxy auf `127.0.0.1:2375` ohne Auth → jeder lokale Prozess hat denselben
Zugriff (wie die `docker`-Gruppe beim Direkt-Socket). In-App-TLS ist NICHT implementiert;
off-host nur über einen betreiber-eigenen TLS-Reverse-Proxy. Der Host ist die
Vertrauensgrenze. **Nebeneffekt:** `access-logs` (historisch) nutzt `docker exec` →
funktioniert **nicht** hinter dem Proxy mit `EXEC:0`; der Live-`logs`-Pfad (container.logs)
schon.
### ADR-013 — Image-Registry: GHCR (Default)
**Status:** Accepted (Default 2026-07-02; jederzeit änderbar). **Entscheidung:**
Das Data-Plane-Image wird nach **GHCR (ghcr.io)** publiziert; Renovate pinnt den
Digest. **Warum:** kostenlos, integriert sich sauber mit GitHub-CI + Renovate-
Digest-Pinning. **Alternativen:** Docker Hub (Pull-Rate-Limits) oder selbst
gehostete/linuxmuster-Registry (mehr Infrastruktur).

---

## Zu verifizierende Site-Fakten (P0, mit Quelle/Datum eintragen)

- Reales `REALM` + Base DN/DC-Suffix der Zielumgebung.
- Exakter Gruppen-DN (`ldbsearch '(sAMAccountName=teachers)' dn`), Präfix-Regel bestätigt.
- LDAP-Helfer-Platzhalter `%u` vs. `%v` (empirisch).
- Subnetz→Schule-Zuordnung; Verhältnis zum bestehenden OPNsense-Proxy (ablösen/parallel).
