<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Teststrategie — linuxmuster-squid

Zwei Tiers. Der **schnelle Tier** läuft lokal/CI; der **schwere Tier** (Docker +
Kerberos) läuft auf **crabbox** (siehe `/test`-Skill). Aggregator:
`bash scripts/tests/run.sh [lint|unit|quick|e2e|all]` — Summary
`N passed, M failed, K skipped`, Exit ≠ 0 bei Fail, jeder Schritt dep-gated.
`e2e`/`all` verweigern ohne `LMNSQUID_ALLOW_REAL=1`.

## Schneller Tier (überall)

- **Python:** `ruff check`, `ruff format --check`, `mypy`, `pytest`
  (Control-Plane-Logik, API-Handler mit httpx-TestClient, CLI-Client).
- **Shell:** `shellcheck` für `image/*.sh`, `scripts/**`.
- **Squid-Config:** `squid -k parse` gegen gerenderte Templates (im Container;
  grün nur mit `squid-openssl`, sobald `ssl_bump` aktiv ist).

## Schwerer Tier — Kerberos-E2E (crabbox)

docker-compose-Stack: `samba-dc` + `squid` + `origin` + `test-client` (Details in
der `/test`-Skill). **Kern-Beweis** (P1), Assertions auf `%{http_code}`:

| Fall | Aktion | Erwartung |
|---|---|---|
| Lehrer erlaubt | `kinit teacher1`; via Lehrer-Instanz | **200** |
| Schüler abgelehnt (authN ok, authZ fail) | `kinit student1`; via Lehrer-Instanz | **403** (nicht 407) |
| Gesperrte Domain | Lehrer → Eintrag aus `blocked.domains` | **403** |
| Kein Ticket | `kdestroy`; Anfrage | **407** |

Der 403-vs-407-Split ist der eigentliche Beweis (authentifiziert-aber-unautorisiert
vs. nicht-authentifiziert).

## Negativ-/Sicherheitskatalog (wächst pro Phase; Teil der DoD)

- **P1:** kein-Ticket→407; Schüler→403; SPN-Mismatch/FQDN-als-IP → kein 200.
- **P2:** gesperrte HTTPS-Domain (SNI/CONNECT)→403 **ohne** Client-CA; erlaubte→200;
  Verhalten bei fehlendem SNI definiert.
- **P3:** Lehrer-Schule-A über Schule-B-Instanz→403; präfixierte Gruppennamen greifen;
  Subnetz-Scope greift.
- **P4:** API ohne Token→401, falscher Token→403; ungültige Instanz-Definition
  abgelehnt; Reconcile idempotent.
- **P5:** Update auf kaputtes Image→Auto-Rollback, Dienst bleibt verfügbar;
  `rollback` deterministisch.
- **P9:** `.deb`-Install→systemd `active`, API/CLI-Smoke; Upgrade/Rollback des Pakets.
- **P10:** Keytab-Perms; Manager-ACL nicht extern erreichbar; API-Bind ≠ 0.0.0.0;
  Bypass/Traversal; DC-Ausfall staut nicht (ttl/grace).

## Regeln

- **Neue/geänderte Auth-/Filter-/Lifecycle-Journey ⇒ E2E-Fall dazu** (Pflicht,
  Teil von „fertig").
- **Nie „grün" behaupten ohne realen Lauf** — `run.sh`-Summary zitieren; SKIP =
  „nicht verifiziert".
- Assertions auf Plain-HTTP-Ziele (Proxy-Status inline in `%{http_code}` sichtbar);
  für HTTPS-CONNECT-Fälle Exit-/Header-Semantik beachten.
