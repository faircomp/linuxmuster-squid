<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/) · [SemVer](https://semver.org/).

## [1.0.0-rc2] - 2026-07-03

### Added
- **Log-Aufbewahrung & -Abfrage:** Access-Log auf `docker/lmnsquid logs` gespiegelt; dauerhafte
  **gzip-rotierte Historie** im persistenten Log-Volume (`logrotate`, `log_retention_days`,
  Default 30, bis 3650). Docker-json-log gedeckelt (`log_max_size/log_max_file`).
- **API/CLI-Abfrage:** `GET /logs?since=&until=&grep=` (live) + neu `GET /logs/access` (historisch,
  durchsucht die `.gz`-Tagesdateien injection-sicher); CLI `logs`/`access-logs`.
- **Datenschutz:** `access_log_enabled` pro Instanz (Requests komplett abschaltbar); Retention =
  dokumentierte Löschfrist (Threat-Model T13).

## [1.0.0-rc1] - 2026-07-03

Erste vollständige, crabbox-verifizierte Fassung. Alle autonom testbaren
Abnahmekriterien sind grün; offene Punkte sind ausschließlich menschliche Gates
(reale Windows-GPO-Abnahme, GPG-Signierung mit dem linuxmuster-Key, site-spezifische
AD-Fakten).

### Added
- **Data-Plane-Image** (`squid-openssl`): expliziter Forward-Proxy, **Kerberos-SSO**
  gegen Samba AD (`negotiate_kerberos_auth`), **AD-Gruppen-Autorisierung**
  (`ext_kerberos_ldap_group_acl`), je **(Schule × Rolle)** ein Container.
- **HTTPS-Filter ohne Entschlüsselung** (SNI peek/splice + CONNECT-`dstdomain`);
  UT-Capitole-Blocklisten-Refresh.
- **Multischool-Isolation** mit Präfix-Regel; deklarative `deploy/instances/*.yaml`.
- **Control-Plane**: FastAPI-REST-API + **Typer-CLI** (dünner Client), docker-py-
  Lifecycle, git-State-Store, Reconciler, Bearer-Auth.
- **Digest-gepinnte Updates mit Health-Auto-Rollback**; Renovate; GHCR-CI.
- **Härtung**: read-only-Rootfs + `cap_drop: ALL` + `no-new-privileges` für die
  Proxy-Container; gehärteter systemd-Dienst.
- **Packaging**: signierbares `.deb` (hermetisches venv) + systemd-Unit; Keytab/DNS-
  und GPO-Deployment-Leitfäden; gefilterter Docker-Socket-Proxy.

### Security
- Strikte Feldvalidierung aller Instanzfelder (Abwehr von Path-Traversal & Injection),
  Image muss `:tag`/`@sha256:` tragen (kein pull-all-tags-DoS), IP-Literal-CONNECT-Deny,
  Token-TOCTOU-Fix, konstant-zeitiger Token-Vergleich, Docker-Socket-Proxy.
  **Alle Befunde eines adversarialen Security-Reviews behoben.**

### Verified (crabbox)
- E2E: Lehrer 200 / Schüler 403 / gesperrt 403 / kein-Ticket 407; HTTPS splice/block;
  Multischool-Isolation; echter docker-py-Container-Lifecycle + Auto-Rollback;
  `.deb`-Install/Upgrade. Unit 41 + mypy + ruff grün.

### Pending (human gates)
- Manuelle Windows-GPO-Abnahme auf echten domänengejointen Clients (`docs/deployment-gpo.md`).
- GPG-Signierung mit dem linuxmuster-Key; reale AD-Fakten (Realm/Base DN/Gruppen-DN).
