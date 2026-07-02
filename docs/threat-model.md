<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Bedrohungsmodell — linuxmuster-squid

Risiken + Gegenmaßnahmen. Wächst pro Roadmap-Phase; die Negativtests dazu stehen in
`docs/test-strategy.md` und sind Teil der jeweiligen Definition of Done.

## Schutzgüter

- **Keytabs** (Kerberos-Service-Credentials) — Diebstahl = Impersonation des
  Proxy-Dienstes in der Domäne.
- **Control-Plane-API + Docker-Socket** — Kompromittierung = **Host-Root**.
- **Filter-/Auth-Integrität** — Umgehung = ungefilterter/unautorisierter
  Internetzugriff für Schüler.
- **Nutzer-Privatsphäre** (Minderjährige) — kein unnötiges Mitlesen von HTTPS-Inhalten.

## Risiken & Gegenmaßnahmen

| # | Risiko | Gegenmaßnahme | Verifikation |
|---|---|---|---|
| T1 | **Keytab-Diebstahl** | Secret (tmpfs, `:ro`), `0600` Host, lesbar nur `proxy`, pro Instanz getrennt, nie ins Env/Log; Compose-File-Secrets nicht at-rest verschlüsselt → Host härten | Perms-Test; kein Keytab in `docker inspect`/Logs |
| T2 | **Proxy-Bypass** (nicht-inline) | OPNsense blockt direkten 80/443-Egress (force-proxy); Client-Subnetze = `SCHOOL_SUBNETS` | E2E + Firewall-Review |
| T3 | **Autorisierungs-Umgehung** (Schüler am Lehrer-Proxy, falsche Gruppen-Zuordnung) | Gruppen-ACL server-seitig erzwungen; GPO-Gruppen == ACL-Gruppen; Präfix-Regel korrekt | E2E: Schüler→403; Multischool-Matrix |
| T4 | **HTTPS-Privatsphäre** | kein SSL-Bump-MITM; nur SNI-Splice/CONNECT; Peek-CA nie verteilt | `squid.conf`-Review; kein `bump`-Verdikt |
| T5 | **Control-Plane-RCE = Host-Root** (Docker-Socket) | Socket-Proxy/rootless; API nur localhost/Mgmt, Token (`compare_digest`)/TLS/mTLS; systemd-Härtung; Audit-Log | API 401/403-Tests; Bind-Check ≠ 0.0.0.0 |
| T6 | **Auth-all-or-nothing / SSO-Ausfall** | Auth nie global abschaltbar per Default; Fallback Kerberos→Basic/LDAP (kein NTLM); SSO-Health überwachen | E2E: kein-Ticket→407 |
| T7 | **DNS/SPN-Fehlkonfig** (stiller Kerberos-Fail) | fwd+rev DNS bzw. `rdns=false`; FQDN==SPN==`VISIBLE_HOSTNAME`; NTP<5min; AES-Enctypes | E2E-Kanonikalisierung; `klist -k` |
| T8 | **Blocklisten-Rot** (Supply-Chain) | eigener UT-Capitole-Refresh (Sidecar/Cron); Ausfall sichtbar machen | Refresh-Job-Test |
| T9 | **Unbeaufsichtigtes Bad-Update → tote Schule** | Digest-Pin, human-merge (Renovate `automerge:false`), Health-gated Update + Auto-Rollback, Known-Good persistiert | E2E: Bad-Image → Rollback |
| T10 | **DC/LDAP-Ausfall staut jede Anfrage** | externe-ACL `ttl/negative_ttl/grace` + Helfer-Concurrency tunen | Lasttest P10 |
| T11 | **Container-Escape/Privileg** | `read_only`-Rootfs + tmpfs, `cap_drop: ALL` (minimal Caps), non-root `proxy`, Manager-ACL localhost | Härtungs-Review P10 |
| T12 | **Exam-Mode** | `<user>-exam` in keiner teachers/students-Gruppe → ACL verweigert; lmn7 deaktiviert Proxy im Prüfungsmodus | Doku + optionaler Test |

## Nicht-Ziele (bewusst)

- Kein Deep-Content-Filtering von HTTPS (keine Entschlüsselung) — Domain-Ebene genügt.
- Keine Absicherung gegen einen böswilligen Domänen-Administrator (AD ist Trust-Anker).
- Keine Fleet-Verwaltung hunderter Sites in 1.0 (CLI+git skaliert auf Dutzende;
  GitOps/Komodo später erwägen).
