<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Decisions (ADRs) — linuxmuster-squid

Short Architecture Decision Records. New decision = new entry; if a decision is
revised, set the old entry to `Superseded by ADR-XXX` instead of deleting it.
Status: `Accepted` (confirmed) · `Assumed` (default, still to be confirmed) ·
`Proposed` · `Superseded`.

---

### ADR-000 — License & SPDX
**Status:** Accepted (confirmed 2026-07-04). **Decision:** `GPL-3.0-or-later`, © Kevin Stenzel; every
file carries a REUSE/SPDX header. The project is REUSE 3.3-compliant (`reuse lint` green, 77/77,
gated in CI); license texts live in `LICENSES/`, non-comment files use `.license` sidecars.
**Why:** consistent with the author's rest of the stack and the GPL ecosystem of linuxmuster.net.
**Org/brand:** `faircomp` — canonical repository `github.com/faircomp/linuxmuster-squid`.

### ADR-001 — Explicit forward proxy, no transparent/intercept
**Status:** Accepted (verified). **Decision:** Exclusively explicit
forward proxy. **Why:** In intercept mode Squid cannot do proxy auth (HTTP 407);
Negotiate/NTLM state is tied to the TCP connection. User/group policy strictly
requires explicit mode. **Source:** Squid wiki Features/Authentication.

### ADR-002 — HTTPS: filter without decryption
**Status:** Accepted (user decision). **Decision:** SNI peek+splice or
CONNECT `dstdomain`; **no** SSL-bump MITM. The peek CA is never distributed to clients.
**Why:** privacy-friendly, no client CA rollout, no breaking of
cert pinning; SSL-bumped traffic could no longer carry Kerberos identity.

### ADR-003 — One instance per (school × role)
**Status:** Accepted (user decision). **Decision:** separate Squid containers
per role/school with their own policy/port/log. **Why:** maximum isolation and
different configs; blast-radius containment.

### ADR-004 — Management via REST API + CLI
**Status:** Accepted (user decision). **Decision:** one core engine,
REST API as the interface, CLI as a thin client. **Why:** no duplicated code, one
audited path; covers lifecycle + secure, digest-pinned update.

### ADR-005 — Stack Python/FastAPI + Typer
**Status:** Accepted (default 2026-07-02; changeable at any time). **Decision:** control plane = FastAPI/uvicorn, CLI = Typer;
Docker via **docker-py (`docker`≥7)**, not stdout parsing of `docker compose`.
**Why:** linuxmuster-api7/webui7 are FastAPI/Python (ecosystem proximity); docker-py
provides structured lifecycle/health/digest APIs. **Alternative:** Go
(single binary) — weighed, deferred.

### ADR-006 — Image from `squid-openssl` (not `squid`)
**Status:** Accepted (verified). **Decision:** install `squid-openssl` + `squidclient`.
**Why:** On Ubuntu 24.04 `squid` is built **without** OpenSSL →
`ssl_bump`/peek-splice impossible; `squid-openssl` (6.14) contains SSL **and** all
Kerberos/LDAP helpers. `squidclient` is a separate package; `ntlm_auth` would come from
`winbind` (only if NTLM fallback is needed). **Source:** packages.ubuntu.com noble
filelists.

### ADR-007 — Authorization via `ext_kerberos_ldap_group_acl`
**Status:** Accepted (verified). **Decision:** group check preferably with
`ext_kerberos_ldap_group_acl` (uses the Kerberos ticket, no bind password in the
config, recursive groups, DC discovery via SRV); `ext_ldap_group_acl` as
alternative with explicit bind/GC. **Open (P0):** verify `%u` vs. `%v` placeholder and
exact group DN against the real DC.
**Verified (P1, E2E 4/4):** The helper only works in the container with
(1) package `libsasl2-modules-gssapi-mit`; (2) `/etc/ldap/ldap.conf` with
`SASL_NOCANON on` — otherwise libldap canonicalizes the SASL host via reverse DNS →
wrong `ldap/` SPN → "Local error"; (3) `/etc/krb5.conf` with `rdns=false`;
(4) a **kinit-capable** principal in the keytab (a real account, not just the
HTTP SPN alias); (5) Negotiate `-s GSS_C_NO_NAME`. In production (domain-joined
proxy with a machine-account keytab) (4)/(5) are satisfied automatically.

### ADR-008 — Network model: port-based, one host keytab (default)
**Status:** Accepted (default 2026-07-02; changeable at any time). **Decision:** instances differ by port +
group policy; one host FQDN/keytab (the SPN is port-independent). **Why:**
simplest DNS/keytab maintenance; each instance still enforces its group.
**Alternative:** macvlan with its own IP/FQDN/keytab per instance (max. isolation +
firewall separation) — on demand.

### ADR-009 — Keytabs supplied by the AD admin (default)
**Status:** Accepted (default 2026-07-02; changeable at any time). **Decision:** the control plane consumes externally supplied
keytabs (secret mount). Auto-provisioning (`msktutil`/`samba-tool`) remains a
**disabled** optional feature. **Why:** fewer privileges/attack surface,
safer MVP.

### ADR-010 — Updates: digest pin + Renovate + health rollback, no Watchtower
**Status:** Accepted (verified). **Decision:** git as source of truth,
`image@sha256:` pin, Renovate (`automerge:false`, merge = go/no-go), controlled
`pull`+`up` with health-check auto-rollback; tooling as a signed `.deb`.
**Why:** Watchtower is archived (2025-12-17), has no rollback, applies breaking
changes blindly, needs a root socket.

### ADR-011 — Packaging via dh-virtualenv
**Status:** Proposed. **Decision:** `.deb` with a hermetic venv at build time
(dh-virtualenv), **no** pip-in-postinst. **Why:** reproducible/signable,
no network/pip-as-root at install time (improvement over webui7/api7); layout
otherwise modeled on linuxmuster. **Note:** build and target Python minor must
match.

### ADR-012 — Docker socket behind a proxy (treat as root-equivalent)
**Status:** Accepted (verified). **Decision:** API strictly bound to **`127.0.0.1`** +
token; access to the socket via `docker-socket-proxy` (only the required endpoints) or
rootless Docker. **Why:** write access to `docker.sock` = passwordless root on
the host; otherwise this undermines the systemd hardening.
**Honest limit (P11.4):** The socket proxy needs `CONTAINERS`+`VOLUMES`+`POST` to
run instances — with that a compromised caller can create a container **with a
host bind mount** = still host root. The proxy **reduces the surface,
but does not downgrade below root**; the real answer is **rootless Docker**. Moreover
the proxy listens on `127.0.0.1:2375` without auth → any local process has the same
access (like the `docker` group with the direct socket). In-app TLS is NOT implemented;
off-host only via an operator-owned TLS reverse proxy. The host is the
trust boundary. **Side effect:** `access-logs` (historical) uses `docker exec` →
does **not** work behind the proxy with `EXEC:0`; the live `logs` path (container.logs)
does.
### ADR-013 — Image registry: GHCR (default)
**Status:** Accepted (default 2026-07-02; changeable at any time). **Decision:**
The data-plane image is published to **GHCR (ghcr.io)**; Renovate pins the
digest. **Why:** free, integrates cleanly with GitHub CI + Renovate
digest pinning. **Alternatives:** Docker Hub (pull rate limits) or self-
hosted/linuxmuster registry (more infrastructure).

---

## Site facts to be verified (P0, enter with source/date)

- Real `REALM` + base DN/DC suffix of the target environment.
- Exact group DN (`ldbsearch '(sAMAccountName=teachers)' dn`), prefix rule confirmed.
- LDAP helper placeholder `%u` vs. `%v` (empirical).
- Subnet→school mapping; relationship to the existing OPNsense proxy (replace/parallel).
