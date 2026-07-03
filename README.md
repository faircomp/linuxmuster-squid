<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# linuxmuster-squid

Containerisierter, mehrinstanzfähiger **Squid-Proxy für [linuxmuster.net](https://linuxmuster.net) 7**
mit **Kerberos-SSO** gegen Samba Active Directory und **gruppenbasierten
Zugriffsregeln** (Lehrer / Schüler), je **(Schule × Rolle)** eine isolierte
Instanz — verwaltet über eine **REST-API + CLI**.

> **Status:** **`v1.0.0-rc1` — code-complete & crabbox-verifiziert** (alle 11 Phasen
> P0–P10, `run.sh all` grün: Unit 41 + mypy + ruff + E2E 9/9 + docker-Integration +
> `.deb`-Install/Upgrade; adversarialer Security-Review mit allen Befunden behoben —
> siehe **[`CHANGELOG.md`](CHANGELOG.md)** / **[`ROADMAP.md`](ROADMAP.md)**). Vor dem
> Produktiveinsatz noch **menschliche Gates**: manuelle Windows-GPO-Abnahme
> (**[`docs/deployment-gpo.md`](docs/deployment-gpo.md)**), GPG-Signierung des `.deb`
> mit dem linuxmuster-Key, site-spezifische AD-Fakten (Realm/Base DN/Gruppen-DN).

## Warum

linuxmuster.net 7 nutzt weiterhin Squid, aber **eingebaut in die OPNsense** — mit
Kerberos-SSO über das Plugin **`os-web-proxy-sso`**, das **abgekündigt/unmaintained**
ist (Entfernung ab OPNsense 26.1 vorgesehen). Gruppen-Policies (Lehrer/Schüler)
hängen an einem fragilen Community-Plugin, **Multischool-Isolation gibt es nicht**,
und der Proxy teilt sich Ressourcen mit Routing/NAT auf der Firewall.

`linuxmuster-squid` löst die Identitäts-/Filterschicht aus der Firewall heraus und
liefert die zwei Dinge sauber nach, die der OPNsense-Weg nie hatte: **robuste
Lehrer/Schüler-Gruppen-Policy** und **Multischool-Isolation** — bei Wiederverwendung
derselben AD-/Kerberos-Infrastruktur, die die Schule schon betreibt.

## Architektur auf einen Blick

- **Data Plane:** N Squid-Container (je Schule × Rolle). Expliziter Forward-Proxy
  (Kerberos-Proxy-Auth ist im transparenten Modus technisch unmöglich),
  Authentifizierung via `negotiate_kerberos_auth`, Autorisierung via
  `ext_kerberos_ldap_group_acl` gegen die AD-Gruppe der Instanz. HTTPS wird
  **nicht entschlüsselt** (SNI-Peek/Splice bzw. CONNECT-`dstdomain`).
- **Control Plane:** gehärteter systemd-Dienst mit **REST-API** (FastAPI) und
  **CLI** (Typer, dünner Client) — legt Instanzen an, konfiguriert Policies und
  **updatet digest-gepinnt mit Health-Check-Auto-Rollback**. Ausgeliefert als
  signiertes `.deb`.

Details: [`docs/architecture.md`](docs/architecture.md).

## Entwicklung & Tests

Der schnelle Tier (Lint/Unit) läuft lokal/CI. Der **schwere Tier** — der reale
Kerberos-E2E (Samba-AD-DC + Squid + Client, der beweist *Lehrer→200 /
Schüler→403 / gesperrt→403 / kein-Ticket→407*) — braucht echtes Linux mit Docker
und läuft auf **crabbox** (siehe die `/test`-Skill). Aggregator:
`bash scripts/tests/run.sh [lint|unit|quick|e2e|all]`.

## Sicherheit (Kurz)

Keytabs sind Domänen-Credentials (Secret/tmpfs, least-privilege). **Keine
HTTPS-Entschlüsselung** (datenschutzfreundlich, kein Client-CA-Rollout). Der
Control-Plane-Docker-Socket-Zugriff ist **root-äquivalent** — API nur an
localhost/Mgmt-Netz, Token/TLS, hinter Socket-Proxy. Mehr:
[`docs/threat-model.md`](docs/threat-model.md) · [`docs/keytab-and-dns.md`](docs/keytab-and-dns.md).

## Lizenz

`GPL-3.0-or-later` (angenommen — siehe `docs/decisions.md`). © Kevin Stenzel.
