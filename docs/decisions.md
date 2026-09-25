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
**Update 2026-09-25:** the Renovate workflow is disabled (Kevin) until Renovate returns with a
GitHub App; digest bumps are raised by hand in PRs meanwhile, still merged by a human.
**`.deb` upgrade lifts instances:** installing a new package runs `update-all` so every
instance follows that package's pinned `DEFAULT_IMAGE` (the apt install is the human
go/no-go), each with health auto-rollback; `lmnsquid update-all` does the same on demand.
**Why:** Watchtower is archived (2025-12-17), has no rollback, applies breaking
changes blindly, needs a root socket.

### ADR-011 — Packaging: hermetic venv in a debhelper package
**Status:** Accepted (debhelper since 7.3.5). **Decision:** `.deb` with a hermetic venv at build time,
**no** pip-in-postinst. **Why:** reproducible/signable,
no network/pip-as-root at install time (improvement over webui7/api7); layout
otherwise modeled on linuxmuster. **Note:** build and target Python minor must
match (`Depends: python3 (>= 3.12), python3 (<< 3.13)`, `Architecture: amd64` for the wheels'
shared objects). **Implementation:** debhelper 13 without dh-virtualenv:
`packaging/build-venv.sh` builds the venv from the hash-pinned locks inside the package
tree, without root; `debian/venv-relocate` rewrites it for `/opt/linuxmuster-squid/venv` and its
`--verify` fails the build if a file still carries the build path, a pip-installed file no
longer matches its RECORD hash or a `.pyc` is stale.

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
does **not** work behind the proxy with `EXEC:0`, and neither does `blocklist reload`
(`squid -k reconfigure` via exec, ADR-014); the live `logs` path (container.logs) does.
### ADR-013 — Image registry: GHCR (default)
**Status:** Accepted (default 2026-07-02; changeable at any time). **Decision:**
The data-plane image is published to **GHCR (ghcr.io)**; its digest is pinned
(by Renovate; by hand while Renovate is disabled, see ADR-010). **Why:** free, integrates cleanly with GitHub CI + Renovate
digest pinning. **Alternatives:** Docker Hub (pull rate limits) or self-
hosted/linuxmuster registry (more infrastructure).

### ADR-014 — Blocklist per instance on the host, directory-mounted, reload via `squid -k reconfigure` (exec)
**Status:** Accepted (2026-09-22, campaign fix 7.3.1). **Decision:** each instance owns
`<blocklists_dir>/<name>/blocked.domains` on the proxy host; the control plane creates it
empty on create/reconcile and bind-mounts the **directory** read-only at `/etc/squid/lists`
(the path the template already reads). Managed via `lmnsquid blocklist <name>
list|add|remove|reload`; entries are normalized to `.example.org` (domain + subdomains);
`reload` runs `squid -k reconfigure` inside the container (docker exec). `lmnsquid rm`
deletes the list with the instance.
**Why:** the image stays read-only and unchanged; the list is a per-instance policy like the
group, so it lives beside the other config under `/etc`; a *directory* mount survives the
atomic replace an editor or `blocklist-refresh.sh` does (a single-file bind mount pins the
inode); reconfigure keeps the cache and client connections. **Not** `docker kill -s HUP`,
although squid is PID 1 and would reconfigure: Docker records every kill(), whatever the
signal, as a manual stop, and an `unless-stopped` container then stays down after a reboot
(seen in the lab). Price: like `access-logs`, `reload` needs `docker exec` (ADR-012).
**Limit (documented):** a blocked HTTPS name is terminated at the TLS handshake, there is
no 403 page without decryption (ADR-002).

### ADR-015 — Build inputs pinned: hashed Python locks, digests, action SHAs, draft-first releases
**Status:** Accepted (2026-09-23, stage A "supply chain" of the linuxmusterDEV archive plan).
**Decision:** every input of the `.deb` build is an immutable reference. The venv's Python
packages (pip included) come from `controlplane/requirements.lock`, compiled with `uv pip
compile --generate-hashes --exclude-newer=P7D` for Python 3.12 on linux/x86_64 (nothing
younger than 7 days is picked) and installed with `--require-hashes --no-deps --only-binary
:all:` (wheels only: building an sdist would fetch its build backend unverified); `lmnsquid` itself is built as a wheel in a throwaway venv whose
setuptools comes from `packaging/requirements-build.lock` (no build isolation, no index), so
nothing unpinned is downloaded while the package is built. The build container
(`lmndev-runner`), the data-plane base image and every GitHub Action are pinned by digest or
commit SHA. Releases are created as drafts, get their assets, are checked against the build and
only then published (the order GitHub's immutable releases need); the release job fails unless
the published release is immutable. Every change comes as a PR a human merges; Renovate
(`renovate.yml`, Thursdays, self-hosted, engine pinned and validated before every run) proposed
them, PyPI releases only once 7 days old, and is disabled since 2026-09-25 (Kevin) until it
returns with a GitHub App, so they are raised by hand meanwhile.
The lock is exactly what its header command produces. The gate (`lock-deps.sh --check`, run by
the fast tier and by every build with the uv the build lock pins, so a lock CI would reject is
never built) accepts only lines uv writes, re-resolves the pins with the header's options including the
7-day cutoff (preferring the locked versions, so it only moves when the lock or its inputs do),
checks that every pin has a cp312 manylinux wheel and that every hash is one PyPI lists.
**Why:** the `.deb` is installed as root on school servers and vouches for everything that ran
in its build; before, each build took whatever PyPI and the moving image/action tags served.
**Tool:** `uv pip compile` over pip-tools because it compiles for a Python version other than
the host's and Renovate's pip-compile manager can re-run it from the lock header. Renovate
rejects `--python-platform`, so the lock is compiled on linux/x86_64 (CI, Renovate, dev box)
with `--python-version=3.12`; environment markers then evaluate as on the target.
**Price:** dependency updates need a merged PR; the lock is regenerated, never hand-edited.

---

## Site facts to be verified (P0, enter with source/date)

- Real `REALM` + base DN/DC suffix of the target environment.
- Exact group DN (`ldbsearch '(sAMAccountName=teachers)' dn`), prefix rule confirmed.
- LDAP helper placeholder `%u` vs. `%v` (empirical).
- Subnet→school mapping; relationship to the existing OPNsense proxy (replace/parallel).
