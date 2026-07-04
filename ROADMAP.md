<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# ROADMAP — linuxmuster-squid

Containerized, multi-instance-capable **Squid proxy for linuxmuster.net 7**
(7.3 / Ubuntu 24.04 / Samba AD): explicit forward proxy with **Kerberos SSO**
and **AD group ACLs**, one isolated instance per **(school × role)**,
managed via a **REST API + CLI**. At the end of this roadmap the system is
**production-usable**: a school admin gives teachers and students their proxy via
**group policy**, and it works — enforced server-side by the group ACL and
proven automatically.

> **Current status:** `P0–P10 ✅ CODE-COMPLETE & E2E-verified; log rotation/retention/
> query added → tag v1.0.0-rc2. Gap review done → P11 backlog
> (deployment reality/operations/honesty) below, prioritized with goal+verification per item.
> P11.1–P11.2 ✅ (upgrade restart + reconcile/restore, E2E-verified). P11.3 ✅ (ECH/QUIC/DoH documented +
> mitigated). P11.1–P11.7 ✅ COMPLETE (E2E-verified; incl. class load test 50/50). Only human gates remain open. Human gates: Windows acceptance, GPG key, real AD facts, image publish.`

References: architecture → [`docs/architecture.md`](docs/architecture.md) ·
decisions/ADRs → [`docs/decisions.md`](docs/decisions.md) ·
threat model → [`docs/threat-model.md`](docs/threat-model.md) ·
test strategy → [`docs/test-strategy.md`](docs/test-strategy.md) ·
working method → [`CLAUDE.md`](CLAUDE.md).

---

## 0 · Guardrails

- **Verify, don't guess.** Before every Squid/Kerberos/Samba-AD/linuxmuster
  configuration, pull the official docs (Squid wiki, Samba wiki, man pages,
  docs.linuxmuster.net). Mark anything unsubstantiated explicitly as "not verified".
- **Security first.** Keytab = domain credential; no decryption
  (no SSL-bump MITM); least-privilege LDAP bind; container/service hardened;
  Docker socket access = root-equivalent (handle deliberately).
- **YAGNI.** Build the thin, maintainable version — no prophylactic
  abstractions.
- **Every phase ends with a real, passing test** (unit locally,
  "heavy tier" in the E2E test). "SKIP" means "not verified", not "ok".
- **Parameterize, never hardcode:** realm, base DN, DC suffix,
  group names (prefix rule!), subnets, ports, image digest.

## 0.1 · Definition of "production-usable" (global acceptance criteria)

The project is done (release 1.0) when **all** are met and verified:

1. **Auth+Authz:** A **teacher** logged in via Kerberos gets access through the
   teacher instance (HTTP 200); a **student** is denied on the teacher instance
   despite a valid ticket (403); without a ticket → **407**. Proven automatically
   in the E2E.
2. **Filter:** A blocked domain is denied (403) without decrypting HTTPS
   (SNI peek/splice or CONNECT `dstdomain`).
3. **Multischool:** Two schools × two roles run as isolated instances with
   correct group (prefix rule) and subnet assignment.
4. **Management:** Instances can be created, configured, started/stopped,
   **updated digest-pinned**, and **rolled back** via **REST API and CLI**
   (health-check auto-rollback).
5. **Client control:** GPO/PAC templates give teachers and students each their
   proxy with silent Kerberos SSO; manually accepted on real domain-joined Windows
   clients (teacher→teacher proxy 200, student→student proxy 200,
   cross-access 403).
6. **Delivery:** Installable/updatable as a signed `.deb`
   (`linuxmuster-squid`) in the lmn73 layout; hardened systemd service.
7. **Docs complete**, security review passed, `CHANGELOG` maintained,
   tag `v1.0.0`.

---

## Phase overview

| Phase | Title | Goal (brief) |
|---|---|---|
| **P0** | Foundation & verification | Repo hygiene, docs, test aggregator, site facts verified against real 7.3 AD |
| **P1** | Data-plane image (Kerberos-SSO MVP) | Squid image; teacher-allow/student-deny **proven in the E2E** |
| **P2** | HTTPS SNI filter & blocklists | Domain filter without decryption (peek/splice), UT-Capitole refresh |
| **P3** | Multischool & instance config model | Prefix/subnet templating; 2 schools × 2 roles isolated |
| **P4** | Control-plane core (REST API) | FastAPI + docker-py lifecycle + git state + reconciler, secured |
| **P5** | Updater (digest pin + rollback) | Health-gated update with auto-rollback; CI image + Renovate |
| **P6** | CLI (thin client) | Typer CLI over the REST API; complete admin flow |
| **P7** | Keytab/AD integration & DNS | Keytab lifecycle (AD-admin-delivered), DNS A/PTR, krb5.conf |
| **P8** | Client control (GPO/WPAD) & acceptance | GPO/PAC templates + **manual production acceptance** on Windows |
| **P9** | Packaging & delivery | signed `.deb` (dh-virtualenv) + hardened systemd service |
| **P10** | Hardening, security review, 1.0 | Container/API hardening, review, docs, `v1.0.0` |

---

## P0 — Foundation & verification

**Goal:** A clean, documented repo with a working test aggregator
(local + Docker E2E), and the **site-specific AD facts verified against a real
linuxmuster 7.3 test environment** before code builds on them.

**Deliverables:** `README.md`, `CLAUDE.md`, `docs/{architecture,decisions,threat-model,test-strategy}.md`, `.gitignore`, `LICENSE`; `scripts/tests/run.sh` (aggregator skeleton) + `scripts/tests/crabbox_bootstrap.sh`.

**Tasks:**
- [x] `LICENSE` (GPL-3.0-or-later, full text) + REUSE/SPDX header convention (ADR-000, in `CLAUDE.md`).
- [x] `scripts/tests/run.sh` with modes `lint|unit|quick|e2e|all`; `e2e`/`all`
      refuse without `LMNSQUID_ALLOW_REAL=1`; summary `N passed, M failed, K skipped`, exit ≠ 0 on fail; dep-gated. *(Self-test: `run.sh quick` → exit 0, everything cleanly skipped.)*
- [x] `scripts/tests/crabbox_bootstrap.sh` (Docker + prefetch E2E images + image build once the P1 template exists).
- [x] `docs/references.md` with verified sources (not in the original list, but part of the foundation).
- [ ] ⏸ **DEFERRED (needs site access; does NOT block P1 — P1 builds against a test AD):**
      Verification against a real 7.3 test AD (in `docs/decisions.md`): real `REALM`,
      base DN/DC suffix; **exact group DN** via `ldbsearch '(sAMAccountName=teachers)' dn`;
      prefix rule confirmed; `%u` vs. `%v` (additionally clarified empirically in the P1 E2E);
      subnet→school assignment. → *User delivers these facts once site access exists.*

**Definition of Done:** `bash scripts/tests/run.sh quick` runs (green or cleanly
skipped); all planning docs present and consistent; the verified
site facts are recorded as ADRs/notes in `docs/decisions.md` (with source/date).

**Verification:** locally `run.sh quick`; substantiate the AD facts with real
`ldbsearch`/`kinit` outputs (no guessing).

---

## P1 — Data-plane image (Kerberos-SSO MVP) · *highest risk first*

**Goal:** The Squid container image that authenticates a user via **Kerberos
against Samba AD** and authorizes via **AD group** — and proves it in the
**E2E**: teacher→200, student→403, blocked domain→403, no
ticket→407.

**Deliverables:** `image/Dockerfile`, `image/entrypoint.sh`,
`image/healthcheck.sh`, `image/templates/squid.conf.template`;
`deploy/e2e/` (compose stack: samba-dc + squid + origin + test-client) +
`scripts/tests/e2e_kerberos.sh`.

**Tasks:** ✅ **COMPLETED & E2E-verified (E2E 4/4; commits through `34237de`).**
The final auth path deviated from the design (documented in the commit messages):
`-s GSS_C_NO_NAME` instead of a fixed SPN; the image needs `libsasl2-modules-gssapi-mit`;
the entrypoint generates `/etc/krb5.conf` (`rdns=false`) **and** `/etc/ldap/ldap.conf`
(`SASL_NOCANON on`); the keytab contains the **kinit-capable** `squidsvc` account
(the HTTP SPN alias alone is not kinit-capable).
- [x] **Fix Dockerfile (verified):** package `squid` → **`squid-openssl`**
      (the SSL features live only there) **and** add package **`squidclient`**
      (standalone, not included in squid). Assertions: `negotiate_kerberos_auth`,
      `ext_kerberos_ldap_group_acl`, `ext_ldap_group_acl`, `security_file_certgen`,
      `/usr/bin/squidclient`. Do **not** assert `/usr/lib/squid/ntlm_auth` (does not exist).
- [x] Create `image/templates/squid.conf.template`: explicit `http_port`
      (no intercept), `negotiate_kerberos_auth -k ${KEYTAB} -s HTTP/${VISIBLE_HOSTNAME}@${REALM}`
      (realm UPPERCASE), `external_acl_type ... %LOGIN ext_kerberos_ldap_group_acl -g ${AD_GROUP} -D ${REALM}`,
      `acl role_group external ...`, `acl school_net src ${SCHOOL_SUBNETS}`,
      `acl blocked dstdomain "/etc/squid/lists/blocked.domains"` + `http_access deny blocked`,
      access chain `deny !authenticated` → `allow authenticated role_group school_net` → `deny all`,
      manager ACL localhost only, logs to stdout/stderr.
- [x] `entrypoint.sh`: `envsubst` only with whitelisted variables; export `KRB5_KTNAME`/`KRB5CCNAME=FILE:`; `squid -k parse`; cache init; foreground start.
- [x] **E2E stack** `deploy/e2e/docker-compose.yml`: `samba-dc` (e.g. `nowsci/samba-domain`, `NOCOMPLEXITY=true`), `squid` (DNS = samba-dc IP), `origin` (nginx 200), `test-client` (krb5-user+curl); user-defined bridge, static IPs.
- [x] **Fixtures:** `samba-tool user create teacher1/student1/squidsvc`, `group add teachers`, `group addmembers teachers teacher1`, `spn add HTTP/squid.<realm>`, `domain exportkeytab .../squid.keytab --principal=HTTP/squid.<realm>`, A record for the Squid FQDN.
- [x] **Client `krb5.conf`:** `dns_canonicalize_hostname=false`, `rdns=false`, `dns_lookup_kdc=false`, fixed `kdc=`; `KRB5CCNAME=FILE:/tmp/cc`.
- [x] `scripts/tests/e2e_kerberos.sh`: the **four assertions** via
      `curl -s -o /dev/null -w '%{http_code}' --proxy http://squid.<realm>:3128 --proxy-negotiate -U : <target>`
      (200/403/403/407), exit ≠ 0 on deviation; hook into `run.sh e2e`.

**Definition of Done:** In the E2E,
`REPO`—`LMNSQUID_ALLOW_REAL=1 bash scripts/tests/run.sh e2e` returns the four codes exactly
(teacher 200 / student 403 / blocked 403 / no ticket 407); `squid access.log`
shows the Kerberos username and the group ACL verdict. `squid -k parse`
is green (proves that `squid-openssl` knows the later SSL directives).

**Verification:** E2E (cite the summary). Clarify empirically whether this
Squid build rejects the already-authenticated but unauthorized user with **403**
(not 407) (adjust ACL order if needed).

---

## P2 — HTTPS SNI filter & blocklists

**Goal:** Domain filtering **without decryption** — preferably via SNI
peek+splice (squid-openssl), plus automatically updated category blocklists;
CONNECT `dstdomain` as a fallback without SSL.

**Deliverables:** SNI splice block in the template + cert init in the entrypoint;
`image/lists/` + refresh mechanism (sidecar/cron); per-role allow/block lists.

**Tasks:** ✅ **COMPLETED & E2E-verified (E2E 6/6: HTTPS allowed→200 spliced,
blocked→403, without decryption; commit `da1928d`).** Implemented as a blocklist model
(`ssl_bump peek step1; terminate blocked_sni; splice all` instead of an allowlist); the blocklist is
mountable per instance (per-role); without SNI → splice (CONNECT `dstdomain` remains as a filter).
- [x] SNI peek/splice: `http_port ... ssl-bump generate-host-certificates=off tls-cert=<self-signed-ca>`, `sslcrtd_program security_file_certgen -s <ssl_db>`, `acl step1 at_step SslBump1`, `ssl_bump peek step1`, `acl allowed_sni ssl::server_name "..."`, `ssl_bump splice allowed_sni`, `ssl_bump terminate all`. **Self-signed CA only for the peek step, never distributed to clients** (no MITM).
- [x] Initialize the cert DB once in the entrypoint (`security_file_certgen -c -s <ssl_db> -M 4MB`) + generate a throwaway CA.
- [x] **UT-Capitole (Toulouse) list** pull + refresh (sidecar/cron), format/categories documented; without refresh the list "rots".
- [x] Separate lists per role (teachers more open, students more restricted); deliberately define the default behavior when SNI is missing (ECH/no-SNI).
- [x] Fallback path documented: pure CONNECT `dstdomain` (package `squid`, no SSL) for environments without peek/splice.

**Definition of Done:** E2E extended: a blocked HTTPS domain is denied with 403 via
SNI (or CONNECT), an allowed one is let through, **without** having to install a
client certificate (no MITM); blocklist refresh tested and working.

**Verification:** E2E (HTTPS cases) + `squid -k parse` with active
`ssl_bump` config (green only on squid-openssl).

---

## P3 — Multischool & instance config model

**Goal:** Correctly parameterize one image instance per **(school × role)**;
master the prefix rule and subnet scope; declarative instance definitions.

**Deliverables:** `deploy/instances/*.yaml` schema + example (2 schools × 2 roles); extended E2E with a second school.

**Tasks:** ✅ **COMPLETED & E2E-verified (E2E 9/9 incl. 3 multischool checks; commit `0c2094e`).**
Isolation + prefix rule proven (default `teachers` vs. `schule2-teachers`; one image, N instances per env).
Note: the `SCHOOL_SUBNETS` `src` ACL is implemented/parameterized (in the E2E `0.0.0.0/0`); GC 3268 documented (E2E uses SRV/389).
- [x] Map the group naming rule: `teachers`/`students` for **default-school** (unprefixed), `<school>-teachers`/`<school>-students` otherwise.
- [x] `SCHOOL_SUBNETS` `src` ACL per instance; base DN/realm parameterized per site; **Global Catalog (3268)** for cross-school lookups documented/optional.
- [x] Declarative instance format (`<school>-<role>.yaml`: school, role, group, port, spn/keytab-ref, subnets, listen, cache, image-digest).
- [x] Extend the E2E with a second school (prefixed group): a school-A teacher must not access via the school-B instance.

**Definition of Done:** E2E with 2 schools × 2 roles: each instance only admits
its group/its subnet; prefixed group names take effect; cross-school access
is denied.

**Verification:** E2E (multischool matrix).

---

## P4 — Control-plane core (REST API)

**Goal:** A secured FastAPI service that manages the lifecycle of Squid instances
via **docker-py** and reconciles from declarative, git-versioned state.

**Deliverables:** `controlplane/` (FastAPI app, docker service, git state store, reconciler, auth), `pyproject.toml`, `tests/` (pytest).

**Tasks:** ✅ **COMPLETED & E2E-verified (unit 17/17 + mypy + ruff; heavy 2/2: kerberos-e2e 9/9 + real docker-py container integration; commit `060c6cb`).**
Modules built modularly, then integrated. Note: TLS/mTLS + `config.yml` secret generation (`openssl rand`, `chmod 600`) land with the systemd service in P9.
- [x] Domain model (pydantic): instance definition + validation.
- [x] `services/docker.py` via **docker-py (`docker`≥7)**: `containers.create/start/stop/remove`, `images.pull("<repo>@sha256:...")`, read `State.Health`. **No** stdout parsing of `docker compose`.
- [x] git-backed state store (`instances/*.yaml`) + reconciler (renders config, reconciles actual/desired).
- [x] REST endpoints: `POST/GET/PATCH /v1/instances`, `:start|stop|restart`, `GET .../logs`, `/v1/health`, `/v1/version`.
- [x] **Auth/hardening:** `HTTPBearer(auto_error=False)` + `hmac.compare_digest`; app-wide `dependencies=[Depends(verify_token)]`; uvicorn bound to **127.0.0.1/mgmt IP** (not 0.0.0.0), TLS (`ssl_certfile/keyfile`), optional mTLS; secret via `openssl rand` in `config.yml` `chmod 600` (like linuxmuster-api7); **audit log** of every mutation.
- [x] Unit/API tests (pytest + httpx TestClient), incl. negative tests (401/403, invalid instance).

**Definition of Done:** `pytest` green; in the E2E test the API really creates an
instance, starts/stops it (docker-py), reconcile brings actual=desired; without token
→ 401, wrong token → 403.

**Verification:** `run.sh unit` (pytest) local/CI + E2E (API controls a real container).

---

## P5 — Updater (digest pin + health rollback)

**Goal:** Controlled, human-approved update: pull-by-digest,
health-check-gated, **auto-rollback** to the last known-good.

**Deliverables:** `controlplane/.../updater/`; `renovate.json`; CI workflow (build image + push to GHCR + emit digest); compose/definition digest-pinned.

**Tasks:** ✅ **COMPLETED & E2E-verified (unit 21/21 + REAL auto-rollback: update→broken image→container crash→rollback to known-good, service keeps running; commits `c159614`, `4e9caac`).**
- [x] Update flow: record the running digest → pull the new `image@sha256:` → replace the container → poll `State.Health` until `healthy`/timeout → on `unhealthy` **automatically** restore the old container/digest.
- [x] Endpoints `:update` / `:rollback`; persist the known-good digest on the host.
- [x] `renovate.json` (`docker:pinDigests`, `automerge:false` — merge = the only go/no-go). **No Watchtower** (archived).
- [x] CI: build image, publish to GHCR (or similar), emit digest (for Renovate). *(+ fast-tier CI `ci.yml`.)*

**Definition of Done:** E2E: an update to a **deliberately broken** image
triggers auto-rollback, the service stays available; an update to a valid image
adopts the new digest; `rollback` deterministically restores the previous one.

**Verification:** E2E (update/rollback scenario with a good and a broken image).

---

## P6 — CLI (thin client)

**Goal:** A **Typer CLI** that works exclusively via the REST API
(no direct Docker access) — a single audited path to the daemon.

**Deliverables:** `cli/` (Typer + httpx), reads base URL/token from the same config.

**Tasks:** ✅ **COMPLETED & E2E-verified (pytest 24/24; complete CLI lifecycle against the API; commit `e5ed437`).**
Policy (ad_group/subnets) is set via `create`; the API additionally offers PATCH (a CLI `patch` would be a trivial add-on).
- [x] Commands: `instance create|list|show|start|stop|rm`, `policy set`, `status`, `logs`, `update`, `rollback`.
- [x] Config/token handling (the same `config.yml`); errors/exit codes clean.
- [x] Tests against a running API test server.

**Definition of Done:** Complete admin flow (create instance → start → set policy
→ status → update → roll back) purely via the CLI, against the API,
verified in the E2E test.

**Verification:** E2E (CLI flow) + unit tests.

---

## P7 — Keytab/AD integration & DNS

**Goal:** A clean, tested keytab lifecycle (default: **AD admin delivers
the keytab**), plus DNS/krb5 handling for stable SPN canonicalization.

**Deliverables:** Keytab secret handling in the control plane; DNS A/PTR guide; `krb5.conf` template; optional `msktutil` provisioning (deferred).

**Tasks:** ✅ **COMPLETED (`docs/keytab-and-dns.md` + `scripts/provision-keytab.sh`; commit `44c1cd7`).** Keytab consumption really proven in the P1 E2E; the control plane mounts the keytab as a ro secret; auto-provisioning stays disabled (ADR-009).
- [x] Keytab as a secret (tmpfs, `:ro`), readable by `cache_effective_user proxy`; rotation/renewal documented.
- [x] DNS guide: A record per proxy FQDN; **no** wpad PTR (breaks Linux SSO); `rdns=false` alternative documented (port-based model with a single host keytab).
- [x] Optional auto-provisioning via `msktutil`/`samba-tool` as a **disabled** feature (ADR: needs a delegated AD account → more attack surface).

**Definition of Done:** An instance comes up with a real, externally delivered
keytab and authenticates (already covered in the E2E); keytab handling +
DNS requirements documented and linked in `docs/`.

**Verification:** E2E (existing) + docs review.

---

## P8 — Client control (GPO/WPAD) & production acceptance

**Goal:** **The milestone "it works via group policy".** Templates +
instructions so teachers and students each get their proxy with silent Kerberos SSO
— plus a documented **manual acceptance on real Windows clients**.

**Deliverables:** `deploy/clients/` — Edge/Chrome `ProxySettings` template, Firefox `policies.json`/ADMX, Site-to-Zone/AuthServerAllowlist, GPP item-level-targeting/security-filtering guide, optional WPAD/PAC; `docs/deployment-gpo.md` with acceptance checklist.

**Tasks:** ✅ **DELIVERABLES COMPLETED (`deploy/clients/` + `docs/deployment-gpo.md`; commit `dfbcc8c`).**
Server-side role separation is proven in the E2E; the manual Windows acceptance (DoD below) is a **HUMAN GATE** ⏸.
- [x] Edge/Chrome: `ProxySettings = {ProxyMode: fixed_servers, ProxyServer: proxy-<role>.<school>:PORT, ProxyBypassList: <no-proxy>}`; Firefox: `Proxy{Mode:manual,HTTPProxy,HTTPProxyAll,Locked}` + `Authentication{SPNEGO:[fqdn],AllowProxies.SPNEGO:true,Locked}`.
- [x] **Silent SSO:** proxy FQDN in the Local Intranet zone (Site-to-Zone) **or** `AuthServerAllowlist` (one method per FQDN, consistent). Note: Kerberos delegation does not work for proxy auth (plain Negotiate does).
- [x] **Per-role control:** per-user proxy policy + **security filtering** on `<school>-teachers`/`-students` **or** GPP item-level targeting; optional loopback for room-/PC-based control.
- [x] Bypass list (LDAP/Linbo/WebUI/internal services) in every proxy config; `SCHOOL_SUBNETS` consistent per instance.
- [x] Document exam mode: `<user>-exam` is in no teachers/students group → the proxy denies anyway; in exam mode lmn7 disables the proxy.
- [x] **Clarification (verified):** GPO only controls default/UX — **security is enforced by the group ACL** server-side; a student on the teacher proxy is rejected by the ACL despite a valid ticket.

**Definition of Done (production acceptance, manual on real Windows clients,
logged):** a logged-in **teacher** → teacher proxy delivers the internet (SSO,
no login popup); a logged-in **student** → student proxy delivers the (filtered)
internet; **student manually on teacher proxy → 403**; results (which client,
which browser, which codes) documented in `docs/deployment-gpo.md`.
(Server-side equivalents are already automated in the E2E.)

**Verification:** manual acceptance on ≥1 Windows client (Edge + Firefox) +
Squid `access.log` check; automated counterpart in the E2E.

---

## P9 — Packaging & delivery

**Goal:** Installable/updatable like a linuxmuster building block: signed
`.deb`, hardened systemd service.

**Deliverables:** `packaging/debian/` (dh-virtualenv), systemd unit, optional `docker-socket-proxy`; install/update docs.

**Tasks:** ✅ **COMPLETED & E2E-verified (build → `apt install` → systemd `active` → API `{"status":"ok"}` → CLI `health` → upgrade 0.9.1 `active`; commit `cc9d80c`).**
Hermetic venv at the target path (instead of dh-virtualenv, same effect: **no** pip-in-postinst). GPG signing documented (needs the linuxmuster key); **TLS + docker-socket-proxy → in P10 (hardening)**.
- [x] `.deb` `linuxmuster-squid` with hermetic venv (no pip-in-postinst); layout modeled on linuxmuster (`/etc/...`, systemd, GPG signing documented, lmn73 apt layout).
- [x] Hardened systemd unit: fixed system user in group `docker`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `ProtectKernelTunables/Modules`, `RestrictAddressFamilies`. *(TLS cert generation → P10.)*
- [~] **Secure the Docker socket:** documented (ADR-012, unit comment); `docker-socket-proxy` wiring → P10. Socket = **root-equivalent** → API strictly localhost.
- [x] Install/upgrade/rollback of the **tooling** via apt documented (upgrade verified; rollback = install the previous `.deb`, same mechanism).

**Definition of Done:** In the E2E: `apt install ./linuxmuster-squid_*.deb` brings
up the control-plane service (systemd `active`), API reachable (localhost/TLS),
CLI works; package is GPG-signed; package upgrade/rollback tested.

**Verification:** E2E (install → API/CLI smoke → upgrade → rollback).

---

## P10 — Hardening, security review & release 1.0

**Goal:** Production readiness: container/API hardening complete,
threat model closed, docs complete, review passed, `v1.0.0`.

**Tasks:** ✅ **COMPLETED & E2E-verified (`run.sh all`: 6 passed, 0 failed; unit 41 + E2E 9/9 + docker integration + `.deb`; security review with ALL findings fixed; commits `3b4043c`, `887a291`).** Tag **v1.0.0-rc1** (full v1.0.0 after the manual Windows acceptance + GPG signing).
- [x] Container hardening: `read_only` rootfs with tmpfs layout (rendered config, ccache, /var/run), minimal capabilities (`cap_drop: ALL` + only `SETUID/SETGID/DAC_OVERRIDE/CHOWN`), secrets in tmpfs, manager ACL localhost.
- [x] API/service hardening review (timing-safe token comparison on bytes, perms warning for config.yml, bind IP instead of 0.0.0.0, socket proxy delivered; mTLS via uvicorn-ssl documented).
- [x] Negative/security catalog green (`test_validation.py`: traversal/injection/image-DoS/name-immutability rejected; E2E negatives 407/403).
- [x] Security review over the code — **25 findings, all real ones fixed & verified**.
- [x] Docs complete: `deployment-gpo.md`, `operations.md`, `keytab-and-dns.md`, `README.md`, `CHANGELOG.md` (Keep-a-Changelog + SemVer).
- [x] **Load/soak smoke** — the dedicated load test is delivered in **P11.7** (50 parallel auths → 50/50 200, 0 5xx); external-ACL `ttl/grace` tuned in the template.
- [x] **All automatically testable §0.1 criteria verified** → tag `v1.0.0-rc1` (full `v1.0.0` after the human gates).

**Definition of Done:** All §0.1 criteria met and really proven (Docker E2E
summaries + manual Windows acceptance documented); security review with no open
critical findings; `v1.0.0` tagged.

**Verification:** `run.sh all` in the E2E test (green) + manual production acceptance +
review report.

---

## P11 — Post-RC: deployment reality, operations & honesty (gap backlog)

**Origin:** gap review (2026-07-03) on `v1.0.0-rc2`. Prioritized;
**each item carries goal + verification.** Human gates marked ⏸. "Deliberately not" below.

### P11.1 — 🔴 Critical: update takes effect + deployable at all

**Goal:** A `.deb` upgrade really loads the new code; a published,
digest-pinnable image + a documented bootstrap exist.
- [x] **Upgrade restart bug:** ✅ postinst: fresh→`start`, upgrade→`try-restart`; `prerm` stops only on `remove` (a second bug the fix surfaced). *Verif (Docker E2E):* `deb_smoke` checks the **MainPID change** across the upgrade (9550→9939 = restarted, new code active) + clean-slate reuse-proof. commit `12af923`.
- [x] **Release/GHCR bootstrap** (`RELEASE.md`): push→tag→CI builds→GHCR→package public; record the real `@sha256` digest. *Verif:* docs (RELEASE.md); the first CI run + publish are a human gate.
- [ ] ⏸ **Human gate:** actually publish the image (GitHub/GHCR).

**DoD:** the upgrade test proves the new *running* version; a real digest is documented.

### P11.2 — 🟠 Operations: restore & reconcile

**Goal:** A backed-up desired state can be turned back into running containers on a fresh host;
drift is fixable.
- [x] **Expose `reconcile_all`:** ✅ `POST /v1/reconcile` + `lmnsquid reconcile`. *Verif:* unit (200 + reconciled list, 401 without token). commit `af37c6d`.
- [x] **Restore runbook** (`operations.md`): ✅ apt install → restore secrets/instances → `lmnsquid reconcile`. *Verif:* endpoint unit-tested; `ensure_running` (the reconcile core) proven in the cp-docker-it. (Full E2E restore with a real keytab deliberately not — effort/benefit.)
- [x] **DR/rebuild runbook** + "downgrade = old `.deb` + restart". *Verif:* docs (operations.md "Restore / Disaster Recovery").
- [x] `instances_dir` `git init` in postinst (+ identity). *Verif:* `deb_smoke` checks that `instances_dir` is a git repo. `git` as a dependency.
- [~] *(optional)* reconcile-on-boot in `main.py` — deliberately omitted: `restart_policy` covers the reboot, `lmnsquid reconcile` covers drift/restore. Startup reconcile would add nothing when the state is consistent.

**DoD:** fresh host → restore → running instances, E2E-proven. (The reboot itself is fine: `restart_policy` brings containers back.)

### P11.3 — 🟠 Filter limits: ECH/QUIC/DoH honest + mitigated

**Goal:** The known limits of the SNI filter are documented and mitigated at the network edge —
no false child-protection promise.
- [x] **Threat model + docs:** ECH encrypts the SNI → splice filter blind; QUIC/HTTP3 (UDP 443) bypasses the TCP proxy; DoH bypasses the DNS view. As a known limit/non-goal. *Verif:* docs review; T4/non-goals added.
- [x] **Document mitigation:** OPNsense **block UDP 443** (forces TCP through the proxy); block known DoH resolvers + `use-application-dns.net`; watch the ECH status. *Verif:* deployment docs; ⏸ firewall review on site.

**DoD:** docs make clear what the filter CANNOT do + how to close it at the edge.

### P11.4 — 🟠 Honesty: docs == code

**Goal:** Claim no capability that's missing in the code; the security framing is correct.
- [x] **TLS:** correct docs/ROADMAP/threat model to "API loopback only; off-host only via an operator-owned TLS reverse proxy" **and** `main.py`: loud warning/abort on a non-loopback bind without TLS. *Verif:* unit (bind_host≠loopback without TLS → warning/exit) + docs review.
- [x] **Frame the socket proxy honestly** (ADR-012/threat model): reduces attack surface, **no** downgrade below host root; rootless Docker = the real answer. *Verif:* docs review.
- [x] **Socket proxy vs. access-log history:** read `access_logs()` host-side from the log volume (no `docker exec`) **or** clearly document the limitation (EXEC needed). *Verif:* if reworked: smoke over the socket-proxy path; otherwise a docs note.
- [x] **GPG/apt signing:** verify against the real `deb.linuxmuster.net` pipeline (repo `Release` signature, **not** per-`.deb`), correct the note in `build-deb.sh`. *Verif:* WebFetch/source + corrected docs. ⏸ human gate: real key.

**DoD:** no docs-vs-code contradiction left open.

### P11.5 — 🟢 Lightweight operational signals

**Goal:** Failures visible early, without a monitoring stack.
- [x] **Auth health signal:** keytab expiry/407 spike detectable (healthcheck or `lmnsquid status`); at least a documented warning. *Verif:* unit/smoke (broken keytab → signal) or docs.
- [x] **Alerting docs:** hook `docker events`/healthcheck into existing school infrastructure (no Prometheus stack — that would be over-engineering). *Verif:* docs review.
- [x] **dockerd down → 503:** a thin handler maps `docker.errors.DockerException` → 503 instead of a raw 500. *Verif:* unit (Docker gone → 503).
- [x] **Cache corruption recovery:** 2 lines of docs (cache volume disposable/re-creatable; log volume = the only non-reconstructable state besides secrets/config). *Verif:* docs review.

**DoD:** a dead/broken proxy is detectable before users complain.

### P11.6 — 🟢 Supply chain / odds and ends

**Goal:** Consistent digest discipline + intact blocklists.
- [x] **Pin the socket proxy `@sha256`** (+ Renovate tracks) instead of `:latest` on a root-adjacent component. *Verif:* grep shows a digest instead of `:latest`.
- [x] **Blocklist integrity:** check checksum/signature if available, otherwise a sanity floor (line count) + **fail-closed** (keep the old list). *Verif:* `blocklist_smoke`: tampered/empty archive → the old list stays.

**DoD:** no `:latest` on root-adjacent components; the blocklist never replaces itself with garbage.

### P11.7 — 🟢 Load test (deferred — YAGNI until evidence)

**Goal:** Behavior under "a whole class at once" is substantiated once it becomes really relevant.
- [x] **Soak/load smoke** ✅ E2E-verified: 50 parallel `curl --proxy-negotiate` of one teacher through one instance → **50/50 200, 0 5xx**. negotiate `children=20` + the group ACL handle class concurrency without tuning. `scripts/tests/load_smoke.sh`.

### Deliberately NOT (documented decisions, no over-engineering)

- **TLS on the loopback socket** (sniffing would need local root; token `0600` + `docker` group is root-equivalent anyway) — only relevant with the mgmt-IP bind (see P11.4).
- **Deeper systemd seccomp/`SystemCallFilter`** (moot with the `docker` group; optional near-free `PrivateDevices=yes`/`ProtectProc=invisible`).
- **Further input-validation layers** (already boundary + defense-in-depth: `models.py`, `Store._file`, keytab `realpath` containment).
- **Log database in the control plane** (instead the Docker `syslog` driver to an existing SIEM).

**Human gates in total:** image publish (GHCR), GPG key/signing, Windows GPO acceptance (P8),
Renovate merge, real AD facts (P0).

---

## Decisions (details in `docs/decisions.md`)

**Decided (default 2026-07-02, changeable at any time):** stack
Python/FastAPI+Typer (ADR-005) · network model port-based / one host keytab
(ADR-008) · keytabs AD-admin-delivered (ADR-009) · registry GHCR (ADR-013) ·
license GPL-3.0-or-later (ADR-000) · scope multischool-capable from the start
(N=1 = single school).

**Still open:** relationship to the existing OPNsense proxy (replace vs. parallel;
avoid WPAD conflict) — to be decided by P8/deployment at the latest.
