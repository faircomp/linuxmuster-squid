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
| T8 | **Blocklist rot** (supply chain) | own UT-Capitole refresh (sidecar/cron); make outage visible | refresh-job test |
| T9 | **Unattended bad update → dead school** | digest pin, human-merge (Renovate `automerge:false`), health-gated update + auto-rollback, known-good persisted | E2E: bad image → rollback |
| T10 | **DC/LDAP outage stalls every request** | external ACL `ttl/negative_ttl/grace` + tune helper concurrency | load test P10 |
| T11 | **Container escape/privilege** | `read_only` rootfs + tmpfs, `cap_drop: ALL` (minimal caps), non-root `proxy`, manager ACL localhost | hardening review P10 |
| T12 | **Exam mode** | `<user>-exam` in no teachers/students group → ACL denies; lmn7 disables the proxy in exam mode | docs + optional test |
| T13 | **Access logs = personal data** (browsing behavior, GDPR) | retention = `log_retention_days` (documented deletion period, default 30), gzip-rotated; access logging disableable per instance (`access_log_enabled:false`); log access only via API token, queries into the audit log; no secrets in the log | retention/rotation smoke; `access_log none` render test |
| T14 | **SNI filter bypass: ECH / QUIC / DoH** | **ECH** (Encrypted Client Hello) encrypts the SNI → splice filter blind; **QUIC/HTTP3** runs over **UDP 443**, bypassing the TCP forward proxy; **DoH** circumvents the DNS view. Limit of name-based filtering — the proxy alone does not close this. **Mitigate at the network edge:** OPNsense **block UDP 443** (forces TCP/443 through the proxy), block known DoH resolvers + `use-application-dns.net` (canary disables Firefox DoH); observe ECH adoption. For real completeness you would need SSL interception (a deliberate non-goal, ADR-002). | firewall review at the site; documented limit |

## Non-goals (deliberate)

- No deep content filtering of HTTPS (no decryption) — domain level suffices.
- No protection against a malicious domain administrator (AD is the trust anchor).
- No fleet management of hundreds of sites in 1.0 (CLI+git scales to dozens;
  consider GitOps/Komodo later).
