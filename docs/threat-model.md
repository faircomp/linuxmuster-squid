<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Threat Model — linuxmuster-squid

Risks + countermeasures. Grows per roadmap phase; the negative tests for it live in
`docs/test-strategy.md` and are part of the respective Definition of Done.

## Assets

- **Keytabs** (Kerberos service credentials) — theft = impersonation of the
  proxy service in the domain.
- **Control-plane API + Docker socket** — compromise = **host root**.
- **Filter/auth integrity** — bypass = unfiltered/unauthorized
  internet access for students.
- **User privacy** (minors) — no unnecessary interception of HTTPS content.

## Risks & Countermeasures

| # | Risk | Countermeasure | Verification |
|---|---|---|---|
| T1 | **Keytab theft** | Secret (tmpfs, `:ro`), `0600` host, readable only by `proxy`, isolated per instance, never in env/log; Compose file secrets not encrypted at rest → harden the host | perms test; no keytab in `docker inspect`/logs |
| T2 | **Proxy bypass** (non-inline) | OPNsense blocks direct 80/443 egress (force-proxy); client subnets = `SCHOOL_SUBNETS` | E2E + firewall review |
| T3 | **Authorization bypass** (student on the teacher proxy, wrong group assignment) | group ACL enforced server-side; GPO groups == ACL groups; prefix rule correct | E2E: student→403; multischool matrix |
| T4 | **HTTPS privacy** | no SSL-bump MITM; only SNI-splice/CONNECT; peek CA never distributed | `squid.conf` review; no `bump` verdict |
| T5 | **Control-plane RCE = host root** (Docker socket) | API **only `127.0.0.1`** + token (`compare_digest`), hardened systemd service, audit log. The socket proxy reduces the endpoint surface, **but does NOT downgrade below host root** (`container create` with host bind is inherently root-equivalent) → the real answer is **rootless Docker**. In-app TLS not implemented; off-host only via an operator-provided TLS reverse proxy (`main.py` warns on non-loopback bind) | API 401/403 tests; bind check ≠ 0.0.0.0 |
| T6 | **Auth all-or-nothing / SSO outage** | auth never globally disableable by default; fallback Kerberos→Basic/LDAP (no NTLM); monitor SSO health | E2E: no ticket→407 |
| T7 | **DNS/SPN misconfig** (silent Kerberos fail) | fwd+rev DNS resp. `rdns=false`; FQDN==SPN==`VISIBLE_HOSTNAME`; NTP<5min; AES enctypes | E2E canonicalization; `klist -k` |
| T8 | **Blocklist rot / tampering** (supply chain) | per-instance list on the host (`/etc/linuxmuster-squid/blocklists/<name>/blocked.domains`, mounted read-only into the container, writable only by root/`lmnsquid`), maintained via `lmnsquid blocklist` + `reload`; category lists via `blocklist-refresh.sh` from a host cron with a fail-closed size floor (a truncated download never replaces the list); make outage visible. **HTTPS limit:** a blocked HTTPS name is cut at the TLS handshake (peek + terminate, no decryption) — the user sees a connection error, no block page; HTTP gets 403 | blocklist smoke; lab proof 7.3.1 (HTTP 403, HTTPS TLS abort) |
| T9 | **Unattended bad update → dead school** | digest pin, human-merge (no automerge; bumps by hand while Renovate is disabled), health-gated update + auto-rollback, known-good persisted | E2E: bad image → rollback |
| T10 | **DC/LDAP outage stalls every request** | external ACL `ttl/negative_ttl/grace` + tune helper concurrency | load test P10 |
| T11 | **Container escape/privilege** | `read_only` rootfs + tmpfs, `cap_drop: ALL` (minimal caps), non-root `proxy`, manager ACL localhost | hardening review P10 |
| T12 | **Exam mode** | `<user>-exam` in no teachers/students group → ACL denies; lmn7 disables the proxy in exam mode | docs + optional test |
| T13 | **Access logs = personal data** (browsing behavior, GDPR) | retention = `log_retention_days` (documented deletion period, default 30), gzip-rotated; access logging disableable per instance (`access_log_enabled:false`); log access only via API token, queries into the audit log; no secrets in the log; `lmnsquid rm` deletes the log volume with the instance (`--keep-logs` only on request) | retention/rotation smoke; `access_log none` render test; rm test |
| T14 | **SNI filter bypass: ECH / QUIC / DoH** | **ECH** (Encrypted Client Hello) encrypts the SNI → splice filter blind; **QUIC/HTTP3** runs over **UDP 443**, bypassing the TCP forward proxy; **DoH** circumvents the DNS view. Limit of name-based filtering — the proxy alone does not close this. **Mitigate at the network edge:** OPNsense **block UDP 443** (forces TCP/443 through the proxy), block known DoH resolvers + `use-application-dns.net` (canary disables Firefox DoH); observe ECH adoption. For real completeness you would need SSL interception (a deliberate non-goal, ADR-002). | firewall review at the site; documented limit |
| T15 | **Poisoned build input** (supply chain of the `.deb`, installed as root) — a compromised or silently changed PyPI release, build image or GitHub Action lands in the package | Python deps (pip included) only from `controlplane/requirements.lock` with SHA-256 hashes (`--require-hashes --no-deps --only-binary :all:`, wheels only), nothing younger than 7 days picked (`--exclude-newer=P7D`), own wheel built without build isolation from a hashed setuptools; build container, data-plane base image and actions pinned by digest/commit SHA; changes only via human-merged PRs (raised by hand while Renovate is disabled); releases published draft-first (immutable releases) with the asset hash checked against the build (ADR-015) | `lock-deps.sh --gate` first in the fast tier AND in every build, before anything from a lock is installed or run (no venv `bin/` on PATH; fixed PATH, `/usr/bin/python3 -I`, the caller's venv/`PYTHON*`/`UV_*`/`PIP_*`/`GIT_*`/`CDPATH`/`BASH_ENV` settings and shell functions removed by `packaging/clean-env.sh`, which names what it leaves: proxies, CA bundles, `DEB_*`, git's global config, and what the caller's first shell already ran): only lines uv writes, uv from a uv-only lock proven with the standard library and run by absolute path, every hash one PyPI publishes for exactly that `name==version`, pins exactly the closure of pyproject/`.in` within 7 days, a cp312 wheel for every pin; so a tag on a commit whose lock never passed CI still cannot be built; `--verify-freeze` fails the build unless each venv is exactly its lock (plus lmnsquid / ensurepip's pip), all `name==version`; not caught: a pin moved to another real release of a needed package, older or newer, at least 7 days old and within the declared requirements (review); a wrong hash or an sdist-only pin stops the build; `scripts/tests/lock_gates.sh` (fast tier, `--build` in CI) keeps the manipulations of the cold verification rejected, also from a shell with a poisoned venv; `make deb` packs only tracked files and runs nothing configured in the checkout's git (`scripts/tests/make_deb.sh`) |

## Non-goals (deliberate)

- No deep content filtering of HTTPS (no decryption) — domain level suffices.
- No protection against a malicious domain administrator (AD is the trust anchor).
- No fleet management of hundreds of sites in 1.0 (CLI+git scales to dozens;
  consider GitOps/Komodo later).
