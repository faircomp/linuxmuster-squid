<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Architektur — linuxmuster-squid

Statusdokument. Bei jeder inhaltlich relevanten Änderung mitpflegen (siehe
`CLAUDE.md` → Doku-Pflege). Quellen der verifizierten Aussagen: siehe
`docs/references.md` (wird in P0 angelegt).

## 1. Kontext: linuxmuster.net 7

- linuxmuster.net **7.3** (Ubuntu 24.04), Identität via **Samba AD DC** auf dem
  linuxmuster-Server; **OPNsense** als Firewall/Router; Sophomorix als
  User-/Device-Backend.
- Standardnetz `10.0.0.0/16`; Server `10.0.0.1`, OPNsense-Gateway `10.0.0.254`.
  Zonen: GREEN (intern/vertrauenswürdig) ↔ RED (Internet).
- **Rollen** liegen im AD-Attribut `sophomorixRole` (teacher/student/examuser/…).
  Nutzbare **Gruppe**: `teachers`/`students` für **default-school** (unpräfixiert),
  `<schule>-teachers`/`<schule>-students` sonst. Bind über einen Sophomorix
  `*-binduser` unter `OU=Management,OU=GLOBAL` — nie als Admin. Schulübergreifende
  Lookups: **Global Catalog 3268**.
- **Bestehender Proxy:** Squid **in der OPNsense** mit Kerberos-SSO über
  `os-web-proxy-sso` — **abgekündigt/unmaintained**. Diese Lücke füllt das Projekt.

## 2. Zielbild: Control Plane / Data Plane

```
   Admin ──CLI (Typer/httpx)──▶ REST-API (FastAPI, localhost-only, Bearer)
                                     │  Reconciler + Updater
                                     │  git-State (instances/*.yaml)
                                     ▼  docker-py (Container-Lifecycle)
        ┌───────────────┬───────────────┬───────────────┐
        ▼               ▼               ▼               ▼
   squid: schuleA-  schuleA-        schuleB-        schuleB-      ← Data Plane
          teachers  students        teachers        students        (Schule×Rolle)
        └── Kerberos-SSO gegen Samba-AD · Gruppen-ACL · Egress ▶ OPNsense (RED)
```

- **Data Plane:** N Squid-Container, je (Schule × Rolle) einer. Ein generisches
  Image, alles Instanz-Spezifische aus Env + Secrets.
- **Control Plane:** gehärteter systemd-Dienst; **eine** Kern-Engine, darüber
  REST-API; die CLI ist ein dünner Client der API (kein doppelter Code).

## 3. Data-Plane-Instanz (Squid)

- **Image:** `FROM ubuntu:24.04` + **`squid-openssl`** (SSL/peek-splice steckt auf
  Debian/Ubuntu nur dort; enthält alle Kerberos/LDAP-Helfer) + `squidclient`
  (eigenes Paket) + `krb5-user` + `gettext-base`. envsubst-Entrypoint rendert
  `squid.conf` pro Instanz aus einem Template (nur Whitelist-Variablen).
- **Auth:** expliziter Forward-Proxy (kein intercept — Proxy-Auth ist dort
  unmöglich). `auth_param negotiate .../negotiate_kerberos_auth -k ${KEYTAB}
  -s HTTP/${VISIBLE_HOSTNAME}@${REALM}`. Realm UPPERCASE; SPN-Host = FQDN, den
  Clients konfigurieren.
- **Authz:** `external_acl_type ... %LOGIN ext_kerberos_ldap_group_acl -g ${AD_GROUP}
  -D ${REALM}` → `acl role_group external ...`. Autorisierung läuft erst nach
  erfolgreicher Authentifizierung (`%LOGIN`).
- **Schul-Scope:** `acl school_net src ${SCHOOL_SUBNETS}` (eine Schule wird über
  ihr Subnetz identifiziert — kein Kennzeichen „auf dem Draht").
- **HTTPS-Filter ohne Entschlüsselung:** bevorzugt SNI **peek + splice**
  (squid-openssl; Wegwerf-CA nur für den Peek-Schritt, **nie** an Clients
  verteilt), Fallback CONNECT-`dstdomain` (kein SSL nötig). Kategorie-Blocklisten:
  UT Capitole/Toulouse mit Refresh-Job.
- **Härtung:** `cache_effective_user proxy`; Keytab als Secret (tmpfs, lesbar für
  `proxy`); `KRB5CCNAME=FILE:` (Kernel-Keyring-ccache scheitert unprivilegiert);
  `read_only`-Rootfs + tmpfs; `cap_drop: ALL` (+ minimal SETUID/SETGID/DAC_OVERRIDE);
  Manager-ACL nur localhost; Logs → stdout/stderr; Healthcheck `squidclient mgr:info`.

## 4. Control Plane

- **REST-API (FastAPI/uvicorn):** CRUD über Instanz-Definitionen +
  Lifecycle-Aktionen (`start/stop/restart/update/rollback/status/logs`).
  `HTTPBearer(auto_error=False)` + `hmac.compare_digest`; App-weite Dependency;
  Bind **nur 127.0.0.1** (In-App-TLS ist NICHT implementiert; off-host ausschließlich über
  einen betreiber-eigenen TLS-Reverse-Proxy — bei non-loopback-Bind warnt `main.py`, weil der
  Token sonst im Klartext liefe); Secret in `config.yml` `chmod 600`; **Audit-Log** jeder Mutation.
- **Reconciler:** deklarativer, git-versionierter State (`instances/*.yaml`) →
  rendert Config, gleicht Ist/Soll ab (docker-py).
- **Updater:** pull-by-**Digest** (`image@sha256:`), Health-gated, **Auto-Rollback**
  auf letzten Known-Good; Renovate (`docker:pinDigests`, `automerge:false`) +
  CI-Image-Publish. Kein Watchtower.
- **CLI (Typer/httpx):** ausschließlich über die REST-API — **ein** auditierter
  Pfad zum Docker-Daemon.
- **Docker-Zugriff:** docker-py; **Socket-Zugriff ist root-äquivalent** → hinter
  `docker-socket-proxy`/rootless Docker, API nie öffentlich.

## 5. Client-Steuerung (Produktivnutzung)

- Explizite Proxy-Zuweisung per **GPO** (Edge/Chrome `ProxySettings=fixed_servers`;
  Firefox `policies.json` `Proxy` + `Authentication.SPNEGO`). Stilles Kerberos-SSO:
  Proxy-FQDN in Local-Intranet-Zone (Site-to-Zone) **oder** `AuthServerAllowlist`.
- **Pro-Rolle:** per-user Proxy-Policy + **Security-Filtering** auf
  `<schule>-teachers`/`-students` bzw. GPP-Item-Level-Targeting; optional Loopback
  für Raum-/PC-basierte Steuerung.
- **Sicherheit erzwingt die Gruppen-ACL, nicht die GPO** — ein Schüler am
  Lehrer-Proxy wird per ACL abgewiesen (403). WPAD/PAC nur als Fallback; **kein
  wpad-PTR** (bricht Linux-SSO).

## 6. Datenflüsse (Auth-Pfad, Kurz)

1. Client (GPO-gesteuert) → CONNECT/GET an Proxy-FQDN:Port.
2. Squid `407 Proxy-Authenticate: Negotiate` → Client sendet Kerberos-Ticket (SSO).
3. `negotiate_kerberos_auth` prüft gegen Keytab → Benutzername (`%LOGIN`).
4. `ext_kerberos_ldap_group_acl` prüft Gruppen-Mitgliedschaft (Ticket/LDAP, SRV).
5. `http_access`: `deny !authenticated` → `allow authenticated role_group
   school_net` → Filter (`deny blocked`) → `deny all`. Ergebnis 200 / 403 / 407.
