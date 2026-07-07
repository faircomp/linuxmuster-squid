<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Architecture — linuxmuster-squid

Status document. Keep it up to date with every substantive change (see
`CLAUDE.md` → Documentation maintenance). Sources for the verified statements: see
`docs/references.md` (created in P0).

## 1. Context: linuxmuster.net 7

- linuxmuster.net **7.3** (Ubuntu 24.04), identity via **Samba AD DC** on the
  linuxmuster server; **OPNsense** as firewall/router; Sophomorix as the
  user/device backend.
- Default network `10.0.0.0/16`; server `10.0.0.1`, OPNsense gateway `10.0.0.254`.
  Zones: GREEN (internal/trusted) ↔ RED (Internet).
- **Roles** live in the AD attribute `sophomorixRole` (teacher/student/examuser/…).
  Usable **group**: `teachers`/`students` for **default-school** (unprefixed),
  `<schule>-teachers`/`<schule>-students` otherwise. Bind via a Sophomorix
  `*-binduser` under `OU=Management,OU=GLOBAL` — never as admin. Cross-school
  lookups: **Global Catalog 3268**.
- **Existing proxy:** Squid **in OPNsense** with Kerberos SSO via
  `os-web-proxy-sso` — **deprecated/unmaintained**. This project fills that gap.

## 2. Target picture: Control Plane / Data Plane

```
   Admin ──CLI (Typer/httpx)──▶ REST-API (FastAPI, localhost-only, Bearer)
                                     │  Reconciler + Updater
                                     │  git state (instances/*.yaml)
                                     ▼  docker-py (container lifecycle)
        ┌───────────────┬───────────────┬───────────────┐
        ▼               ▼               ▼               ▼
   squid: schuleA-  schuleA-        schuleB-        schuleB-      ← Data Plane
          teachers  students        teachers        students        (school×role)
        └── Kerberos-SSO against Samba-AD · group-ACL · Egress ▶ OPNsense (RED)
```

- **Data Plane:** N Squid containers, one per (school × role). One generic
  image, everything instance-specific from env + secrets.
- **Control Plane:** hardened systemd service; **one** core engine, with the
  REST-API on top; the CLI is a thin client of the API (no duplicated code).

## 3. Data Plane instance (Squid)

- **Image:** `FROM ubuntu:24.04` + **`squid-openssl`** (on Debian/Ubuntu,
  SSL/peek-splice lives only there; includes all Kerberos/LDAP helpers) + `squidclient`
  (separate package) + `krb5-user` + `gettext-base`. The envsubst entrypoint renders
  `squid.conf` per instance from a template (whitelist variables only).
- **Auth:** explicit forward proxy (no intercept — proxy auth is impossible
  there). `auth_param negotiate .../negotiate_kerberos_auth -k ${KEYTAB}
  -s GSS_C_NO_NAME` — Squid accepts **any** principal present in the keytab (key
  match), so the `HTTP/<connect-fqdn>@REALM` SPN(s) the clients target (realm
  UPPERCASE) only need to exist in the keytab. The SPN host is the FQDN clients
  configure; the port is not part of the SPN.
- **Authz:** `external_acl_type ... %LOGIN ext_kerberos_ldap_group_acl -g ${AD_GROUP}
  -D ${REALM}` → `acl role_group external ...`. Authorization runs only after
  successful authentication (`%LOGIN`).
- **School scope:** `acl school_net src ${SCHOOL_SUBNETS}` (a school is identified
  by its subnet — no marker "on the wire").
- **HTTPS filtering without decryption:** preferably SNI **peek + splice**
  (squid-openssl; throwaway CA only for the peek step, **never** distributed to
  clients), fallback CONNECT `dstdomain` (no SSL needed). Category blocklists:
  UT Capitole/Toulouse with a refresh job.
- **Hardening:** `cache_effective_user proxy`; Keytab as a secret (tmpfs, readable by
  `proxy`); `KRB5CCNAME=FILE:` (the kernel-keyring ccache fails when unprivileged);
  `read_only` rootfs + tmpfs; `cap_drop: ALL` (+ minimal SETUID/SETGID/DAC_OVERRIDE);
  manager ACL localhost only; logs → stdout/stderr; healthcheck `squidclient mgr:info`.

## 4. Control Plane

- **REST-API (FastAPI/uvicorn):** CRUD over instance definitions +
  lifecycle actions (`start/stop/restart/update/rollback/status/logs`).
  `HTTPBearer(auto_error=False)` + `hmac.compare_digest`; app-wide dependency;
  bind **127.0.0.1 only** (in-app TLS is NOT implemented; off-host only via
  an operator-owned TLS reverse proxy — on a non-loopback bind `main.py` warns, because the
  token would otherwise travel in cleartext); secret in `config.yml` `chmod 600`; **audit log** of every mutation.
- **Reconciler:** declarative, git-versioned state (`instances/*.yaml`) →
  renders config, reconciles actual against desired state (docker-py).
- **Updater:** pull-by-**digest** (`image@sha256:`), health-gated, **auto-rollback**
  to the last known-good; Renovate (`docker:pinDigests`, `automerge:false`) +
  CI image publish. No Watchtower.
- **CLI (Typer/httpx):** exclusively via the REST-API — **one** audited
  path to the Docker daemon.
- **Docker access:** docker-py; **socket access is root-equivalent** → behind
  `docker-socket-proxy`/rootless Docker, API never public.

## 5. Client control (production use)

- Explicit proxy assignment via **GPO** (Edge/Chrome `ProxySettings=fixed_servers`;
  Firefox `policies.json` `Proxy` + `Authentication.SPNEGO`). Silent Kerberos SSO:
  proxy FQDN in the Local Intranet zone (Site-to-Zone) **or** `AuthServerAllowlist`.
- **Per role:** per-user proxy policy + **security filtering** on
  `<schule>-teachers`/`-students` or GPP item-level targeting; optional loopback
  for room/PC-based control.
- **Security is enforced by the group ACL, not the GPO** — a student on the
  teacher proxy is rejected by the ACL (403). WPAD/PAC only as a fallback; **no
  wpad-PTR** (breaks Linux SSO).

## 6. Data flows (auth path, brief)

1. Client (GPO-controlled) → CONNECT/GET to proxy FQDN:port.
2. Squid `407 Proxy-Authenticate: Negotiate` → client sends a Kerberos ticket (SSO).
3. `negotiate_kerberos_auth` checks against the Keytab → username (`%LOGIN`).
4. `ext_kerberos_ldap_group_acl` checks group membership (ticket/LDAP, SRV).
5. `http_access`: `deny !authenticated` → `allow authenticated role_group
   school_net` → filter (`deny blocked`) → `deny all`. Result 200 / 403 / 407.
