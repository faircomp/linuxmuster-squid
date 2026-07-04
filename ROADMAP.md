<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# ROADMAP — linuxmuster-squid

Containerisierter, mehrinstanzfähiger **Squid-Proxy für linuxmuster.net 7**
(7.3 / Ubuntu 24.04 / Samba AD): expliziter Forward-Proxy mit **Kerberos-SSO**
und **AD-Gruppen-ACLs**, je **(Schule × Rolle)** eine isolierte Instanz,
gesteuert über eine **REST-API + CLI**. Am Ende dieser Roadmap ist das System
**produktiv nutzbar**: ein Schul-Admin gibt Lehrern und Schülern per
**Gruppenrichtlinie** ihren Proxy, und es funktioniert — server-seitig durch die
Gruppen-ACL erzwungen und automatisiert bewiesen.

> **Aktueller Stand:** `P0–P10 ✅ CODE-COMPLETE & crabbox-verifiziert; Log-Rotation/Retention/
> Abfrage nachgezogen → Tag v1.0.0-rc2. Multi-Perspektiven-Gap-Review gemacht → P11-Backlog
> (Deployment-Realität/Betrieb/Ehrlichkeit) unten, priorisiert mit Ziel+Verifikation je Punkt.
> P11.1–P11.2 ✅ (Upgrade-Restart + reconcile/restore, crabbox-verifiziert). P11.3 ✅ (ECH/QUIC/DoH dokumentiert +
> mitigiert). P11.1–P11.7 ✅ KOMPLETT (autonom, crabbox-verifiziert; inkl. Klassen-Lasttest 50/50). Offen NUR Human-Gates. Human-Gates: Windows-Abnahme, GPG-Key, reale AD-Fakten, Image-Publish.` (Fortschritts-Zeiger.)

Verweise: Architektur → [`docs/architecture.md`](docs/architecture.md) ·
Entscheidungen/ADRs → [`docs/decisions.md`](docs/decisions.md) ·
Bedrohungsmodell → [`docs/threat-model.md`](docs/threat-model.md) ·
Teststrategie → [`docs/test-strategy.md`](docs/test-strategy.md) ·
Arbeitsweise → [`CLAUDE.md`](CLAUDE.md).

---

## 0 · Leitplanken

- **Verifizieren statt raten.** Vor jeder Squid-/Kerberos-/Samba-AD-/linuxmuster-
  Konfiguration die offizielle Doku ziehen (Squid-Wiki, Samba-Wiki, man-pages,
  docs.linuxmuster.net). Unbelegtes explizit als „nicht verifiziert" markieren.
- **Sicherheit zuerst.** Keytab = Domänen-Credential; keine Entschlüsselung
  (kein SSL-Bump-MITM); least-privilege LDAP-Bind; Container/Service gehärtet;
  Docker-Socket-Zugriff = root-äquivalent (bewusst behandeln).
- **YAGNI.** Die dünne, wartbare Version bauen — keine prophylaktischen
  Abstraktionen.
- **Jede Phase endet mit einem realen, bestandenen Test** (Unit lokal,
  „heavy tier" auf crabbox). „SKIP" heißt „nicht verifiziert", nicht „ok".
- **Parametrisieren, nie hartkodieren:** Realm, Base DN, DC-Suffix,
  Gruppennamen (Präfix-Regel!), Subnetze, Ports, Image-Digest.

## 0.1 · Definition „produktiv nutzbar" (globale Abnahmekriterien)

Das Projekt ist fertig (Release 1.0), wenn **alle** erfüllt und verifiziert sind:

1. **Auth+Authz:** Ein per Kerberos angemeldeter **Lehrer** erhält über die
   Lehrer-Instanz Zugriff (HTTP 200); ein **Schüler** wird auf der Lehrer-Instanz
   trotz gültigem Ticket **abgelehnt** (403); ohne Ticket → **407**. Automatisiert
   im crabbox-E2E bewiesen.
2. **Filter:** Eine gesperrte Domain wird abgelehnt (403), ohne HTTPS zu
   entschlüsseln (SNI-Peek/Splice oder CONNECT-`dstdomain`).
3. **Multischool:** Zwei Schulen × zwei Rollen laufen als isolierte Instanzen mit
   korrekter Gruppen- (Präfix-Regel) und Subnetz-Zuordnung.
4. **Verwaltung:** Instanzen lassen sich über **REST-API und CLI** anlegen,
   konfigurieren, starten/stoppen, **digest-gepinnt updaten** und **zurückrollen**
   (Health-Check-Auto-Rollback).
5. **Client-Steuerung:** GPO-/PAC-Vorlagen liefern Lehrern und Schülern je ihren
   Proxy mit stillem Kerberos-SSO; auf echten domänengejointen Windows-Clients
   manuell abgenommen (Lehrer→Lehrer-Proxy 200, Schüler→Schüler-Proxy 200,
   Quer-Zugriff 403).
6. **Auslieferung:** Installierbar/aktualisierbar als signiertes `.deb`
   (`linuxmuster-squid`) im lmn73-Layout; gehärteter systemd-Dienst.
7. **Doku vollständig**, Security-Review bestanden, `CHANGELOG` gepflegt,
   Tag `v1.0.0`.

## 0.2 · Ausführung als autonome Schleife (`/loop`)

Diese Roadmap ist als `/loop`-Vorlage gebaut. **Eine Iteration =**

1. **Wählen:** oberste offene Aufgabe (`[ ]`) der aktuellen Phase.
2. **Umsetzen:** chirurgisch, nur was die Aufgabe verlangt (siehe `CLAUDE.md`).
3. **Verifizieren:** gemäß der **Definition of Done (DoD)** der Phase — Unit/Lint
   lokal bzw. im CI, „heavy tier" (Docker/Kerberos-E2E) auf **crabbox** (siehe
   `/test`-Skill). Ergebnis-Summary zitieren.
4. **Abhaken & Zeiger setzen:** Aufgabe `[x]`, „Aktueller Stand"-Zeile oben
   aktualisieren; Doku im selben Commit pflegen.
5. **Committen:** Conventional Commits, ein Commit pro logischem Schritt.

Eine **Phase gilt als fertig**, wenn alle ihre Aufgaben `[x]` sind **und** ihre
DoD real bestanden wurde (crabbox-Summary `N passed, 0 failed`). Erst dann die
nächste Phase beginnen. Reihenfolge einhalten — spätere Phasen bauen auf früheren.

---

## Phasenübersicht

| Phase | Titel | Ziel (Kurz) |
|---|---|---|
| **P0** | Fundament & Verifikation | Repo-Hygiene, Doku, Test-Aggregator, Site-Fakten gegen echtes 7.3-AD verifiziert |
| **P1** | Data-Plane-Image (Kerberos-SSO-MVP) | Squid-Image; Lehrer-allow/Schüler-deny **im crabbox-E2E bewiesen** |
| **P2** | HTTPS-SNI-Filter & Blocklisten | Domainfilter ohne Entschlüsselung (peek/splice), UT-Capitole-Refresh |
| **P3** | Multischool & Instanz-Konfigmodell | Präfix-/Subnetz-Templating; 2 Schulen × 2 Rollen isoliert |
| **P4** | Control-Plane-Kern (REST-API) | FastAPI + docker-py-Lifecycle + git-State + Reconciler, abgesichert |
| **P5** | Updater (Digest-Pin + Rollback) | Health-gated Update mit Auto-Rollback; CI-Image + Renovate |
| **P6** | CLI (dünner Client) | Typer-CLI über die REST-API; kompletter Admin-Flow |
| **P7** | Keytab-/AD-Integration & DNS | Keytab-Lifecycle (AD-Admin-geliefert), DNS-A/PTR, krb5.conf |
| **P8** | Client-Steuerung (GPO/WPAD) & Abnahme | GPO/PAC-Vorlagen + **manuelle Produktiv-Abnahme** auf Windows |
| **P9** | Packaging & Auslieferung | signiertes `.deb` (dh-virtualenv) + gehärteter systemd-Dienst |
| **P10** | Härtung, Security-Review, 1.0 | Container/API-Härtung, Review, Docs, `v1.0.0` |

---

## P0 — Fundament & Verifikation

**Ziel:** Ein sauberes, dokumentiertes Repo mit einem lauffähigen Test-Aggregator
(lokal + crabbox), und die **site-spezifischen AD-Fakten gegen eine echte
linuxmuster-7.3-Test-Umgebung verifiziert**, bevor Code darauf aufbaut.

**Deliverables:** `README.md`, `CLAUDE.md`, `docs/{architecture,decisions,threat-model,test-strategy}.md`, `.gitignore`, `LICENSE`; `scripts/tests/run.sh` (Aggregator-Skelett) + `scripts/tests/crabbox_bootstrap.sh`; angepasste `/test`-Skill.

**Aufgaben:**
- [x] `LICENSE` (GPL-3.0-or-later, Volltext) + REUSE/SPDX-Header-Konvention (ADR-000, in `CLAUDE.md`).
- [x] `scripts/tests/run.sh` mit Modi `lint|unit|quick|e2e|all`; `e2e`/`all`
      verweigern ohne `LMNSQUID_ALLOW_REAL=1`; Summary `N passed, M failed, K skipped`, Exit ≠ 0 bei Fail; dep-gated. *(Selbsttest: `run.sh quick` → Exit 0, alles sauber geskippt.)*
- [x] `scripts/tests/crabbox_bootstrap.sh` (Docker + E2E-Images vorziehen + Image-Build, sobald das P1-Template existiert).
- [x] `/test`-Skill final auf dieses Projekt zugeschnitten (heavy tier = Kerberos-E2E).
- [x] `docs/references.md` mit verifizierten Quellen (nicht in der ursprünglichen Liste, aber Teil des Fundaments).
- [ ] ⏸ **VERSCHOBEN (braucht Site-Zugang; blockiert P1 NICHT — P1 baut gegen ein Test-AD):**
      Verifikation gegen echtes 7.3-Test-AD (in `docs/decisions.md`): reales `REALM`,
      Base DN/DC-Suffix; **exakter Gruppen-DN** via `ldbsearch '(sAMAccountName=teachers)' dn`;
      Präfix-Regel bestätigt; `%u` vs. `%v` (wird zusätzlich im P1-E2E empirisch geklärt);
      Subnetz→Schule-Zuordnung. → *Nutzer liefert diese Fakten, wenn Site-Zugang besteht.*

**Definition of Done:** `bash scripts/tests/run.sh quick` läuft (grün oder sauber
geskippt); alle Planungsdocs vorhanden und konsistent; die verifizierten
Site-Fakten stehen als ADRs/Notizen in `docs/decisions.md` (mit Quelle/Datum).

**Verifikation:** lokal `run.sh quick`; die AD-Fakten mit echten
`ldbsearch`/`kinit`-Ausgaben belegen (kein Raten).

---

## P1 — Data-Plane-Image (Kerberos-SSO-MVP) · *höchstes Risiko zuerst*

**Ziel:** Das Squid-Container-Image, das einen Nutzer per **Kerberos gegen
Samba-AD** authentifiziert und per **AD-Gruppe** autorisiert — und das im
**crabbox-E2E** beweist: Lehrer→200, Schüler→403, gesperrte Domain→403, kein
Ticket→407.

**Deliverables:** `image/Dockerfile`, `image/entrypoint.sh`,
`image/healthcheck.sh`, `image/templates/squid.conf.template`;
`deploy/e2e/` (compose-Stack: samba-dc + squid + origin + test-client) +
`scripts/tests/e2e_kerberos.sh`.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (E2E 4/4; Commits bis `34237de`).**
Der finale Auth-Weg wich vom Entwurf ab (in den Commit-Messages dokumentiert):
`-s GSS_C_NO_NAME` statt fixem SPN; Image braucht `libsasl2-modules-gssapi-mit`;
Entrypoint generiert `/etc/krb5.conf` (`rdns=false`) **und** `/etc/ldap/ldap.conf`
(`SASL_NOCANON on`); der Keytab enthält den **kinit-fähigen** `squidsvc`-Account
(der HTTP-SPN-Alias allein ist nicht kinit-fähig).
- [x] **Dockerfile korrigieren (verifiziert):** Paket `squid` → **`squid-openssl`**
      (SSL-Features stecken nur dort) **und** Paket **`squidclient`** ergänzen
      (eigenständig, nicht in squid enthalten). Assertions: `negotiate_kerberos_auth`,
      `ext_kerberos_ldap_group_acl`, `ext_ldap_group_acl`, `security_file_certgen`,
      `/usr/bin/squidclient`. **Nicht** `/usr/lib/squid/ntlm_auth` asserten (existiert nicht).
- [x] `image/templates/squid.conf.template` erstellen: expliziter `http_port`
      (kein intercept), `negotiate_kerberos_auth -k ${KEYTAB} -s HTTP/${VISIBLE_HOSTNAME}@${REALM}`
      (Realm UPPERCASE), `external_acl_type ... %LOGIN ext_kerberos_ldap_group_acl -g ${AD_GROUP} -D ${REALM}`,
      `acl role_group external ...`, `acl school_net src ${SCHOOL_SUBNETS}`,
      `acl blocked dstdomain "/etc/squid/lists/blocked.domains"` + `http_access deny blocked`,
      Zugriffskette `deny !authenticated` → `allow authenticated role_group school_net` → `deny all`,
      Manager-ACL nur localhost, Logs nach stdout/stderr.
- [x] `entrypoint.sh`: `envsubst` nur mit Whitelist-Variablen; `KRB5_KTNAME`/`KRB5CCNAME=FILE:` exportieren; `squid -k parse`; Cache-Init; Foreground-Start.
- [x] **E2E-Stack** `deploy/e2e/docker-compose.yml`: `samba-dc` (z. B. `nowsci/samba-domain`, `NOCOMPLEXITY=true`), `squid` (DNS = samba-dc-IP), `origin` (nginx 200), `test-client` (krb5-user+curl); user-defined bridge, statische IPs.
- [x] **Fixtures:** `samba-tool user create teacher1/student1/squidsvc`, `group add teachers`, `group addmembers teachers teacher1`, `spn add HTTP/squid.<realm>`, `domain exportkeytab .../squid.keytab --principal=HTTP/squid.<realm>`, A-Record für den Squid-FQDN.
- [x] **Client-`krb5.conf`:** `dns_canonicalize_hostname=false`, `rdns=false`, `dns_lookup_kdc=false`, fixe `kdc=`; `KRB5CCNAME=FILE:/tmp/cc`.
- [x] `scripts/tests/e2e_kerberos.sh`: die **vier Assertions** über
      `curl -s -o /dev/null -w '%{http_code}' --proxy http://squid.<realm>:3128 --proxy-negotiate -U : <ziel>`
      (200/403/403/407), Exit ≠ 0 bei Abweichung; in `run.sh e2e` einhängen.

**Definition of Done:** Auf crabbox liefert
`REPO`—`LMNSQUID_ALLOW_REAL=1 bash scripts/tests/run.sh e2e` die vier Codes exakt
(Lehrer 200 / Schüler 403 / gesperrt 403 / kein-Ticket 407); `squid access.log`
zeigt den Kerberos-Benutzernamen und das Gruppen-ACL-Verdikt. `squid -k parse`
ist grün (beweist, dass `squid-openssl` die spätere SSL-Direktiven kennt).

**Verifikation:** crabbox-E2E (Summary zitieren). Empirisch klären, ob dieser
Squid-Build den bereits authentifizierten, aber unautorisierten Nutzer mit **403**
(nicht 407) ablehnt (ACL-Reihenfolge ggf. anpassen).

---

## P2 — HTTPS-SNI-Filter & Blocklisten

**Ziel:** Domainfilterung **ohne Entschlüsselung** — bevorzugt via SNI
peek+splice (squid-openssl), plus automatisch aktualisierte Kategorie-Blocklisten;
CONNECT-`dstdomain` als Fallback ohne SSL.

**Deliverables:** SNI-Splice-Block im Template + Cert-Init im Entrypoint;
`image/lists/` + Refresh-Mechanismus (Sidecar/Cron); pro-Rolle Allow/Block-Listen.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (E2E 6/6: HTTPS erlaubt→200 gespliced,
gesperrt→403, ohne Entschlüsselung; commit `da1928d`).** Umgesetzt als Blocklist-Modell
(`ssl_bump peek step1; terminate blocked_sni; splice all` statt Allowlist); Blocklist ist
pro Instanz mountbar (pro-Rolle); ohne SNI → splice (CONNECT-`dstdomain` bleibt als Filter).
- [x] SNI peek/splice: `http_port ... ssl-bump generate-host-certificates=off tls-cert=<self-signed-ca>`, `sslcrtd_program security_file_certgen -s <ssl_db>`, `acl step1 at_step SslBump1`, `ssl_bump peek step1`, `acl allowed_sni ssl::server_name "..."`, `ssl_bump splice allowed_sni`, `ssl_bump terminate all`. **Self-signed CA nur für den Peek-Schritt, wird nie an Clients verteilt** (kein MITM).
- [x] Cert-DB einmalig im Entrypoint initialisieren (`security_file_certgen -c -s <ssl_db> -M 4MB`) + Wegwerf-CA erzeugen.
- [x] **UT-Capitole-(Toulouse-)Liste** ziehen + refreshen (Sidecar/Cron), Format/Kategorien dokumentiert; ohne Refresh „verrottet" die Liste.
- [x] Pro Rolle getrennte Listen (Lehrer offener, Schüler enger); Default-Verhalten bei fehlendem SNI (ECH/kein-SNI) bewusst festlegen.
- [x] Fallback-Pfad dokumentiert: reines CONNECT-`dstdomain` (Paket `squid`, kein SSL) für Umgebungen ohne peek/splice.

**Definition of Done:** crabbox-E2E erweitert: gesperrte HTTPS-Domain wird per SNI
(bzw. CONNECT) mit 403 abgelehnt, erlaubte durchgelassen, **ohne** dass ein
Client-Zertifikat installiert werden muss (kein MITM); Blocklisten-Refresh
lauffähig getestet.

**Verifikation:** crabbox-E2E (HTTPS-Fälle) + `squid -k parse` mit aktiver
`ssl_bump`-Konfig (grün nur auf squid-openssl).

---

## P3 — Multischool & Instanz-Konfigmodell

**Ziel:** Eine Image-Instanz pro **(Schule × Rolle)** korrekt parametrisieren;
Präfix-Regel und Subnetz-Scope beherrschen; deklarative Instanz-Definitionen.

**Deliverables:** `deploy/instances/*.yaml`-Schema + Beispiel (2 Schulen × 2 Rollen); erweiterte E2E mit zweiter Schule.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (E2E 9/9 inkl. 3 Multischool-Checks; commit `0c2094e`).**
Isolation + Präfix-Regel bewiesen (default `teachers` vs. `schule2-teachers`; eine Image, N Instanzen per Env).
Hinweis: `SCHOOL_SUBNETS`-`src`-ACL ist implementiert/parametrisiert (im E2E `0.0.0.0/0`); GC 3268 dokumentiert (E2E nutzt SRV/389).
- [x] Gruppen-Namensregel abbilden: `teachers`/`students` für **default-school** (unpräfixiert), `<schule>-teachers`/`<schule>-students` sonst.
- [x] `SCHOOL_SUBNETS`-`src`-ACL je Instanz; Base DN/Realm je Site parametrisiert; **Global Catalog (3268)** für schulübergreifende Lookups dokumentiert/optional.
- [x] Deklaratives Instanz-Format (`<schule>-<rolle>.yaml`: school, role, group, port, spn/keytab-ref, subnets, listen, cache, image-digest).
- [x] E2E um eine zweite Schule (präfixierte Gruppe) erweitern: Lehrer-Schule-A darf nicht über Schule-B-Instanz.

**Definition of Done:** crabbox-E2E mit 2 Schulen × 2 Rollen: jede Instanz lässt
nur ihre Gruppe/ihr Subnetz zu; präfixierte Gruppennamen greifen; Quer-Schul-Zugriff
wird abgelehnt.

**Verifikation:** crabbox-E2E (Multischool-Matrix).

---

## P4 — Control-Plane-Kern (REST-API)

**Ziel:** Ein abgesicherter FastAPI-Dienst, der Squid-Instanzen über **docker-py**
lebenszyklisch verwaltet und aus deklarativem, git-versioniertem State
rekonziliert.

**Deliverables:** `controlplane/` (FastAPI-App, docker-Service, git-State-Store, Reconciler, Auth), `pyproject.toml`, `tests/` (pytest).

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (unit 17/17 + mypy + ruff; heavy 2/2: kerberos-e2e 9/9 + echte docker-py-Container-Integration; commit `060c6cb`).**
Module parallel per Workflow erzeugt, dann integriert. Hinweis: TLS/mTLS + `config.yml`-Secret-Generierung (`openssl rand`, `chmod 600`) landen mit dem systemd-Dienst in P9.
- [x] Domänenmodell (pydantic): Instanz-Definition + Validierung.
- [x] `services/docker.py` über **docker-py (`docker`≥7)**: `containers.create/start/stop/remove`, `images.pull("<repo>@sha256:...")`, `State.Health` lesen. **Kein** stdout-Parsing von `docker compose`.
- [x] git-gestützter State-Store (`instances/*.yaml`) + Reconciler (rendert Config, gleicht Ist/Soll ab).
- [x] REST-Endpunkte: `POST/GET/PATCH /v1/instances`, `:start|stop|restart`, `GET .../logs`, `/v1/health`, `/v1/version`.
- [x] **Auth/Härtung:** `HTTPBearer(auto_error=False)` + `hmac.compare_digest`; App-weite `dependencies=[Depends(verify_token)]`; uvicorn an **127.0.0.1/Mgmt-IP** gebunden (nicht 0.0.0.0), TLS (`ssl_certfile/keyfile`), optional mTLS; Secret via `openssl rand` in `config.yml` `chmod 600` (wie linuxmuster-api7); **Audit-Log** jeder Mutation.
- [x] Unit-/API-Tests (pytest + httpx-TestClient), inkl. Negativtests (401/403, ungültige Instanz).

**Definition of Done:** `pytest` grün; auf crabbox legt die API real eine
Instanz an, startet/stoppt sie (docker-py), Reconcile bringt Ist=Soll; ohne Token
→ 401, falscher Token → 403.

**Verifikation:** `run.sh unit` (pytest) lokal/CI + crabbox-E2E (API steuert echten Container).

---

## P5 — Updater (Digest-Pin + Health-Rollback)

**Ziel:** Kontrolliertes, menschlich freigegebenes Update: pull-by-digest,
Health-Check-gated, **Auto-Rollback** auf den letzten Known-Good.

**Deliverables:** `controlplane/.../updater/`; `renovate.json`; CI-Workflow (Image bauen + nach GHCR pushen + Digest ausgeben); Compose/Definition digest-gepinnt.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (unit 21/21 + REALER Auto-Rollback: Update→kaputtes Image→Container-Crash→Rollback auf Known-Good, Dienst läuft weiter; commits `c159614`, `4e9caac`).**
- [x] Update-Ablauf: laufenden Digest festhalten → neuen `image@sha256:` pullen → Container ersetzen → `State.Health` bis `healthy`/Timeout pollen → bei `unhealthy` **automatisch** alten Container/Digest wiederherstellen.
- [x] Endpunkte `:update` / `:rollback`; Known-Good-Digest auf Host persistieren.
- [x] `renovate.json` (`docker:pinDigests`, `automerge:false` — Merge = einziges Go/No-Go). **Kein Watchtower** (archiviert).
- [x] CI: Image bauen, nach GHCR (o. ä.) publizieren, Digest emittieren (für Renovate). *(+ Fast-Tier-CI `ci.yml`.)*

**Definition of Done:** crabbox-E2E: Update auf ein **absichtlich kaputtes** Image
löst Auto-Rollback aus, Dienst bleibt verfügbar; Update auf gültiges Image
übernimmt den neuen Digest; `rollback` stellt den vorherigen deterministisch her.

**Verifikation:** crabbox-E2E (Update-/Rollback-Szenario mit gutem und kaputtem Image).

---

## P6 — CLI (dünner Client)

**Ziel:** Eine **Typer-CLI**, die ausschließlich über die REST-API arbeitet
(kein direkter Docker-Zugriff) — ein einziger auditierter Pfad zum Daemon.

**Deliverables:** `cli/` (Typer + httpx), liest Base-URL/Token aus derselben Config.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (pytest 24/24; kompletter CLI-Lifecycle gegen die API; commit `e5ed437`).**
Policy (ad_group/Subnetze) wird via `create` gesetzt; die API bietet zusätzlich PATCH (ein CLI-`patch` wäre trivialer Zusatz).
- [x] Kommandos: `instance create|list|show|start|stop|rm`, `policy set`, `status`, `logs`, `update`, `rollback`.
- [x] Config-/Token-Handling (dieselbe `config.yml`); Fehler/Exit-Codes sauber.
- [x] Tests gegen einen laufenden API-Testserver.

**Definition of Done:** Kompletter Admin-Flow (Instanz anlegen → starten → Policy
setzen → Status → updaten → zurückrollen) rein über die CLI, gegen die API,
auf crabbox verifiziert.

**Verifikation:** crabbox-E2E (CLI-Flow) + Unit-Tests.

---

## P7 — Keytab-/AD-Integration & DNS

**Ziel:** Sauberer, getesteter Keytab-Lifecycle (Standard: **AD-Admin liefert
Keytab**), plus DNS-/krb5-Handling für stabile SPN-Kanonikalisierung.

**Deliverables:** Keytab-Secret-Handling in der Control-Plane; DNS-A/PTR-Leitfaden; `krb5.conf`-Vorlage; optional `msktutil`-Provisionierung (zurückgestellt).

**Aufgaben:** ✅ **ABGESCHLOSSEN (`docs/keytab-and-dns.md` + `scripts/provision-keytab.sh`; commit `44c1cd7`).** Keytab-Consumption real bewiesen im P1-E2E; Control-Plane mountet den Keytab als ro-Secret; Auto-Provisionierung bleibt abgeschaltet (ADR-009).
- [x] Keytab als Secret (tmpfs, `:ro`), lesbar für `cache_effective_user proxy`; Rotation/Erneuerung dokumentiert.
- [x] DNS-Leitfaden: A-Record je Proxy-FQDN; **kein** wpad-PTR (bricht Linux-SSO); `rdns=false`-Alternative dokumentiert (Port-basiertes Modell mit einem Host-Keytab).
- [x] Optionale Auto-Provisionierung via `msktutil`/`samba-tool` als **abgeschaltetes** Feature (ADR: braucht delegiertes AD-Konto → mehr Angriffsfläche).

**Definition of Done:** Eine Instanz kommt mit einem realen, extern gelieferten
Keytab hoch und authentifiziert (im E2E bereits abgedeckt); Keytab-Handling +
DNS-Anforderungen dokumentiert und in `docs/` verlinkt.

**Verifikation:** crabbox-E2E (bestehend) + Doku-Review.

---

## P8 — Client-Steuerung (GPO/WPAD) & Produktiv-Abnahme

**Ziel:** **Der Meilenstein „es funktioniert per Gruppenrichtlinie".** Vorlagen +
Anleitung, damit Lehrer und Schüler je ihren Proxy mit stillem Kerberos-SSO
bekommen — plus eine dokumentierte **manuelle Abnahme auf echten Windows-Clients**.

**Deliverables:** `deploy/clients/` — Edge/Chrome-`ProxySettings`-Vorlage, Firefox `policies.json`/ADMX, Site-to-Zone/AuthServerAllowlist, GPP-Item-Level-Targeting-/Security-Filtering-Anleitung, optional WPAD/PAC; `docs/deployment-gpo.md` mit Abnahme-Checkliste.

**Aufgaben:** ✅ **DELIVERABLES ABGESCHLOSSEN (`deploy/clients/` + `docs/deployment-gpo.md`; commit `dfbcc8c`).**
Server-seitige Rollen-Trennung ist im crabbox-E2E bewiesen; die manuelle Windows-Abnahme (DoD unten) ist ein **HUMAN-GATE** ⏸.
- [x] Edge/Chrome: `ProxySettings = {ProxyMode: fixed_servers, ProxyServer: proxy-<rolle>.<schule>:PORT, ProxyBypassList: <no-proxy>}`; Firefox: `Proxy{Mode:manual,HTTPProxy,HTTPProxyAll,Locked}` + `Authentication{SPNEGO:[fqdn],AllowProxies.SPNEGO:true,Locked}`.
- [x] **Stilles SSO:** Proxy-FQDN in Local-Intranet-Zone (Site-to-Zone) **oder** `AuthServerAllowlist` (eine Methode je FQDN, konsistent). Hinweis: Kerberos-Delegation funktioniert nicht für Proxy-Auth (plain Negotiate schon).
- [x] **Pro-Rolle-Steuerung:** per-user Proxy-Policy + **Security-Filtering** auf `<schule>-teachers`/`-students` **oder** GPP-Item-Level-Targeting; optional Loopback für Raum-/PC-basierte Steuerung.
- [x] Bypass-Liste (LDAP/Linbo/WebUI/interne Dienste) in jede Proxy-Config; `SCHOOL_SUBNETS` je Instanz konsistent.
- [x] Exam-Mode dokumentieren: `<user>-exam` ist in keiner teachers/students-Gruppe → Proxy verweigert ohnehin; lmn7 deaktiviert im Prüfungsmodus den Proxy.
- [x] **Klarstellung (verifiziert):** GPO steuert nur Default/UX — die **Sicherheit erzwingt die Gruppen-ACL** server-seitig; ein Schüler am Lehrer-Proxy wird trotz gültigem Ticket per ACL abgewiesen.

**Definition of Done (Produktiv-Abnahme, manuell auf echten Windows-Clients,
protokolliert):** angemeldeter **Lehrer** → Lehrer-Proxy liefert Internet (SSO,
kein Login-Popup); angemeldeter **Schüler** → Schüler-Proxy liefert (gefiltert)
Internet; **Schüler manuell auf Lehrer-Proxy → 403**; Ergebnisse (welcher Client,
welcher Browser, welche Codes) in `docs/deployment-gpo.md` dokumentiert.
(Server-seitige Äquivalente sind im crabbox-E2E bereits automatisiert.)

**Verifikation:** manuelle Abnahme auf ≥1 Windows-Client (Edge + Firefox) +
Squid-`access.log`-Kontrolle; automatisiertes Pendant im crabbox-E2E.

---

## P9 — Packaging & Auslieferung

**Ziel:** Installierbar/aktualisierbar wie ein linuxmuster-Baustein: signiertes
`.deb`, gehärteter systemd-Dienst.

**Deliverables:** `packaging/debian/` (dh-virtualenv), systemd-Unit, optional `docker-socket-proxy`; Install-/Update-Doku.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (build → `apt install` → systemd `active` → API `{"status":"ok"}` → CLI `health` → Upgrade 0.9.1 `active`; commit `cc9d80c`).**
Hermetisches venv am Ziel-Pfad (statt dh-virtualenv, gleiche Wirkung: **kein** pip-in-postinst). GPG-Signierung dokumentiert (braucht den linuxmuster-Key); **TLS + docker-socket-proxy → in P10 (Härtung)**.
- [x] `.deb` `linuxmuster-squid` mit hermetischem venv (kein pip-in-postinst); Layout an linuxmuster angelehnt (`/etc/...`, systemd, GPG-Signierung dokumentiert, lmn73-apt-Layout).
- [x] Gehärtete systemd-Unit: fester System-User in Gruppe `docker`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `ProtectKernelTunables/Modules`, `RestrictAddressFamilies`. *(TLS-Cert-Erzeugung → P10.)*
- [~] **Docker-Socket absichern:** dokumentiert (ADR-012, Unit-Kommentar); `docker-socket-proxy`-Verdrahtung → P10. Socket = **root-äquivalent** → API strikt localhost.
- [x] Install/Upgrade/Rollback der **Tooling** via apt dokumentiert (Upgrade verifiziert; Rollback = vorheriges `.deb` installieren, gleicher Mechanismus).

**Definition of Done:** Auf crabbox: `apt install ./linuxmuster-squid_*.deb` bringt
den Control-Plane-Dienst hoch (systemd `active`), API erreichbar (localhost/TLS),
CLI funktioniert; Paket ist GPG-signiert; Upgrade/Rollback des Pakets getestet.

**Verifikation:** crabbox-E2E (Install → API/CLI-Smoke → Upgrade → Rollback).

---

## P10 — Härtung, Security-Review & Release 1.0

**Ziel:** Produktionsreife: Container-/API-Härtung abgeschlossen,
Bedrohungsmodell geschlossen, Doku vollständig, Review bestanden, `v1.0.0`.

**Aufgaben:** ✅ **ABGESCHLOSSEN & crabbox-verifiziert (`run.sh all`: 6 passed, 0 failed; Unit 41 + E2E 9/9 + docker-Integration + `.deb`; adversarialer Security-Review mit ALLEN Befunden behoben; commits `3b4043c`, `887a291`).** Tag **v1.0.0-rc1** (volles v1.0.0 nach der manuellen Windows-Abnahme + GPG-Signierung).
- [x] Container-Härtung: `read_only`-Rootfs mit tmpfs-Layout (gerenderte Config, ccache, /var/run), minimale Capabilities (`cap_drop: ALL` + nur `SETUID/SETGID/DAC_OVERRIDE/CHOWN`), Secrets in tmpfs, Manager-ACL localhost.
- [x] API-/Dienst-Härtung-Review (timing-sicherer Token-Vergleich auf bytes, Perms-Warnung für config.yml, Bind-IP statt 0.0.0.0, Socket-Proxy geliefert; mTLS via uvicorn-ssl dokumentiert).
- [x] Negativ-/Sicherheitskatalog grün (`test_validation.py`: Traversal/Injection/Image-DoS/Name-Immutability abgelehnt; E2E-Negatives 407/403).
- [x] Adversarialer Security-Review (5 Reviewer über den Code) — **25 Befunde, alle echten behoben & verifiziert**.
- [x] Doku vollständig: `deployment-gpo.md`, `operations.md`, `keytab-and-dns.md`, `README.md`, `CHANGELOG.md` (Keep-a-Changelog + SemVer).
- [x] **Last-/Soak-Smoke** — der dedizierte Lasttest ist in **P11.7** nachgeliefert (50 parallele Auth → 50/50 200, 0 5xx); externe-ACL-`ttl/grace` im Template getunt.
- [x] **Alle autonom testbaren §0.1-Kriterien verifiziert** → Tag `v1.0.0-rc1` (volles `v1.0.0` nach den Human-Gates).

**Definition of Done:** Alle §0.1-Kriterien erfüllt und real bewiesen (crabbox-
Summaries + manuelle Windows-Abnahme dokumentiert); Security-Review ohne offene
kritische Befunde; `v1.0.0` getaggt.

**Verifikation:** `run.sh all` auf crabbox (grün) + manuelle Produktiv-Abnahme +
Review-Report.

---

## P11 — Post-RC: Deployment-Realität, Betrieb & Ehrlichkeit (Gap-Backlog)

**Herkunft:** Multi-Perspektiven-Gap-Review (2026-07-03) auf `v1.0.0-rc2`. Priorisiert;
**jeder Punkt trägt Ziel + Verifikation.** Human-Gates ⏸ markiert. „Bewusst nicht" unten.

### P11.1 — 🔴 Kritisch: Update wirkt + überhaupt deploybar

**Ziel:** Ein `.deb`-Upgrade lädt wirklich den neuen Code; es existiert ein publiziertes,
digest-pinbares Image + ein dokumentierter Bootstrap.
- [x] **Upgrade-Restart-Bug:** ✅ postinst: Frisch→`start`, Upgrade→`try-restart`; `prerm` stoppt nur bei `remove` (zweiter Bug, den der Fix aufdeckte). *Verif (crabbox):* `deb_smoke` prüft **MainPID-Wechsel** über das Upgrade (9550→9939 = neu gestartet, neuer Code aktiv) + clean-slate reuse-fest. commit `12af923`.
- [x] **Release/GHCR-Bootstrap** (`RELEASE.md`): push→tag→CI baut→GHCR→Package public; realen `@sha256`-Digest festhalten. *Verif:* Doku (RELEASE.md); erster CI-Run + Publish sind Human-Gate.
- [ ] ⏸ **Human-Gate:** Image tatsächlich publizieren (GitHub/GHCR).

**DoD:** Upgrade-Test beweist die neue *laufende* Version; ein echter Digest ist dokumentiert.

### P11.2 — 🟠 Betrieb: Restore & Reconcile

**Ziel:** Gesicherter Soll-Zustand lässt sich auf frischem Host wieder in laufende Container
überführen; Drift ist behebbar.
- [x] **`reconcile_all` exponieren:** ✅ `POST /v1/reconcile` + `lmnsquid reconcile`. *Verif:* Unit (200 + reconciled-Liste, 401 ohne Token). commit `af37c6d`.
- [x] **Restore-Runbook** (`operations.md`): ✅ apt install → secrets/instances zurückspielen → `lmnsquid reconcile`. *Verif:* Endpoint unit-getestet; `ensure_running` (der reconcile-Kern) im cp-docker-it bewiesen. (Voll-E2E-Restore mit echtem Keytab bewusst nicht — Aufwand/Nutzen.)
- [x] **DR/Rebuild-Runbook** + „Downgrade = altes `.deb` + Restart". *Verif:* Doku (operations.md „Restore / Disaster-Recovery").
- [x] `instances_dir` `git init` im postinst (+ Identität). *Verif:* `deb_smoke` prüft, dass `instances_dir` ein git-Repo ist. `git` als Dependency.
- [~] *(optional)* reconcile-on-boot in `main.py` — bewusst weggelassen: `restart_policy` deckt den Reboot ab, `lmnsquid reconcile` deckt Drift/Restore. Startup-Reconcile brächte bei konsistentem Zustand nichts.

**DoD:** frischer Host → Restore → laufende Instanzen, crabbox-bewiesen. (Reboot selbst ist ok: `restart_policy` bringt Container zurück.)

### P11.3 — 🟠 Filter-Grenzen: ECH/QUIC/DoH ehrlich + mitigiert

**Ziel:** Die bekannten Grenzen des SNI-Filters sind dokumentiert und am Netzrand mitigiert —
kein falsches Kinderschutz-Versprechen.
- [x] **Threat-Model + docs:** ECH verschlüsselt die SNI → Splice-Filter blind; QUIC/HTTP3 (UDP 443) umgeht den TCP-Proxy; DoH umgeht die DNS-Sicht. Als bekannte Grenze/Nicht-Ziel. *Verif:* Doku-Review; T4/Nicht-Ziele ergänzt.
- [x] **Mitigation dokumentieren:** OPNsense **UDP 443 blocken** (erzwingt TCP durch den Proxy); bekannte DoH-Resolver + `use-application-dns.net` blocken; ECH-Status beobachten. *Verif:* Deployment-Doku; ⏸ Firewall-Review am Standort.

**DoD:** Doku macht klar, was der Filter NICHT kann + wie man es am Rand schließt.

### P11.4 — 🟠 Ehrlichkeit: Doku == Code

**Ziel:** Keine Fähigkeit behaupten, die im Code fehlt; Sicherheits-Framing stimmt.
- [x] **TLS:** Doku/ROADMAP/Threat-Model auf „API nur loopback; off-host nur via betreiber-eigenen TLS-Reverse-Proxy" korrigieren **und** `main.py`: laute Warnung/Abbruch bei non-loopback-Bind ohne TLS. *Verif:* Unit (bind_host≠loopback ohne TLS → Warnung/Exit) + Doku-Review.
- [x] **Socket-Proxy ehrlich framen** (ADR-012/Threat-Model): reduziert Angriffsfläche, **kein** Downgrade unter Host-Root; rootless Docker = echte Antwort. *Verif:* Doku-Review.
- [x] **Socket-Proxy vs. Access-Log-Historie:** `access_logs()` host-seitig aus dem Log-Volume lesen (kein `docker exec`) **oder** die Einschränkung (EXEC nötig) klar dokumentieren. *Verif:* falls Umbau: Smoke über den Socket-Proxy-Pfad; sonst Doku-Note.
- [x] **GPG/apt-Signierung:** gegen die echte `deb.linuxmuster.net`-Pipeline verifizieren (Repo-`Release`-Signatur, **nicht** per-`.deb`), Note in `build-deb.sh` korrigieren. *Verif:* WebFetch/Quelle + korrigierte Doku. ⏸ Human-Gate: echter Key.

**DoD:** kein Doku-vs-Code-Widerspruch mehr offen.

### P11.5 — 🟢 Leichtgewichtige Betriebs-Signale

**Ziel:** Ausfälle früh sichtbar, ohne Monitoring-Stack.
- [x] **Auth-Health-Signal:** Keytab-Ablauf/407-Spike erkennbar (Healthcheck oder `lmnsquid status`); mind. dokumentierte Warnung. *Verif:* Unit/Smoke (kaputter Keytab → Signal) oder Doku.
- [x] **Alerting-Doku:** `docker events`/Healthcheck an vorhandene Schul-Infra hängen (kein Prometheus-Stack — das wäre Über­engineering). *Verif:* Doku-Review.
- [x] **dockerd-down → 503:** schmaler Handler mappt `docker.errors.DockerException` → 503 statt rohem 500. *Verif:* Unit (Docker weg → 503).
- [x] **Cache-Korruption-Recovery:** 2 Zeilen Doku (Cache-Volume wegwerfbar/neu erzeugbar; Log-Volume = einziger nicht-rekonstruierbarer Zustand neben secrets/config). *Verif:* Doku-Review.

**DoD:** ein toter/kaputter Proxy ist erkennbar, bevor Nutzer klagen.

### P11.6 — 🟢 Supply-Chain / Kleinkram

**Ziel:** Konsistente Digest-Disziplin + integre Blocklisten.
- [x] **Socket-Proxy `@sha256` pinnen** (+ Renovate trackt) statt `:latest` auf einer Root-nahen Komponente. *Verif:* grep zeigt Digest statt `:latest`.
- [x] **Blocklisten-Integrität:** Checksum/Signatur prüfen falls verfügbar, sonst Sanity-Floor (Zeilenzahl) + **fail-closed** (alte Liste behalten). *Verif:* `blocklist_smoke`: manipuliertes/leeres Archiv → alte Liste bleibt.

**DoD:** kein `:latest` auf Root-nahen Komponenten; die Blocklist ersetzt sich nie durch Müll.

### P11.7 — 🟢 Lasttest (verschoben — YAGNI bis Evidenz)

**Ziel:** Verhalten unter „ganze Klasse gleichzeitig" ist belegt, wenn es real relevant wird.
- [x] **Soak/Load-Smoke** ✅ crabbox-verifiziert: 50 parallele `curl --proxy-negotiate` eines Lehrers durch eine Instanz → **50/50 200, 0 5xx**. negotiate `children=20` + Gruppen-ACL halten die Klassen-Concurrency ohne Tuning. `scripts/tests/load_smoke.sh`.

### Bewusst NICHT (dokumentierte Entscheidungen, kein Über­engineering)

- **TLS auf dem Loopback-Socket** (Sniffing bräuchte lokalen Root; Token `0600` + `docker`-Gruppe eh root-äquivalent) — nur relevant beim Mgmt-IP-Bind (siehe P11.4).
- **Tiefere systemd-seccomp/`SystemCallFilter`** (mit `docker`-Gruppe moot; optional near-free `PrivateDevices=yes`/`ProtectProc=invisible`).
- **Weitere Input-Validierungs-Schichten** (schon Boundary + defense-in-depth: `models.py`, `Store._file`, keytab-`realpath`-Containment).
- **Log-Datenbank in der Control-Plane** (stattdessen Docker-`syslog`-Treiber an vorhandenes SIEM).

**Human-Gates gesamt:** Image publish (GHCR), GPG-Key/Signierung, Windows-GPO-Abnahme (P8),
Renovate-Merge, reale AD-Fakten (P0).

---

## Entscheidungen (Details in `docs/decisions.md`)

**Festgelegt (Default 2026-07-02, jederzeit änderbar):** Stack
Python/FastAPI+Typer (ADR-005) · Netzmodell port-basiert / ein Host-Keytab
(ADR-008) · Keytabs AD-Admin-geliefert (ADR-009) · Registry GHCR (ADR-013) ·
Lizenz GPL-3.0-or-later (ADR-000) · Scope multischool-fähig von Anfang an
(N=1 = Einzelschule).

**Noch offen:** Verhältnis zum bestehenden OPNsense-Proxy (ablösen vs. parallel;
WPAD-Konflikt vermeiden) — spätestens in P8/Deployment zu entscheiden.
