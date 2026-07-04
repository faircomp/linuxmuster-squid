---
# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: test
description: Run linuxmuster-squid's real heavy-tier tests on a leased crabbox Linux box — the docker-compose Kerberos E2E (Samba AD DC + Squid + client) the dev box can't run. Use when asked to run integration/e2e/heavy tests, verify the Kerberos auth/group-ACL/filter flow on real Linux, or before a release.
---

# Testing linuxmuster-squid on crabbox

The fast tier (ruff / mypy / pytest / shellcheck) runs anywhere and in CI. The
**heavy tier** — the real docker-compose stack (**Samba AD DC + the Squid image +
a Kerberos client**) that proves *teacher→200 / student→403 / blocked-domain→403 /
no-ticket→407*, plus the multi-school matrix, the update/rollback flow, and the
`.deb` install smoke — needs a real Linux box with **Docker**, which the sandboxed
dev box lacks. crabbox leases an ephemeral Proxmox VM, rsyncs the working tree,
runs the suite, and tears down.

Provider env (proxmox) comes from `.claude/settings.json` (+ the secret in the
gitignored `.claude/settings.local.json`). Confirm with `crabbox doctor`.

## Single-box flow (warm once → reuse the slug → stop)

1. **Warm** a box and note its slug: `crabbox warmup` → e.g. `slug=silver-lobster`.
2. **Hydrate** it once (installs Docker, builds the Squid image, pulls the
   Samba-AD-DC image + client tooling):
   `crabbox run --id <slug> -- 'bash scripts/tests/crabbox_bootstrap.sh'`
3. **Run** the aggregator — one command, dependency-gated:
   - `crabbox run --id <slug> -- 'bash scripts/tests/run.sh quick'`                       (ruff + mypy + pytest + shellcheck)
   - `crabbox run --id <slug> -- 'LMNSQUID_ALLOW_REAL=1 bash scripts/tests/run.sh e2e'`   (docker-compose Kerberos E2E)
   - `crabbox run --id <slug> -- 'LMNSQUID_ALLOW_REAL=1 bash scripts/tests/run.sh all'`   (quick + e2e + smoke)
4. **Inspect** on failure: `crabbox ssh --id <slug>` (live), or read the newest
   `.crabbox/captures/*.tar.gz` (logs, timings, ready-made stop command).
5. **Stop** when done: `crabbox stop --id <slug>`.

`run.sh` prints `N passed, M failed, K skipped` and exits non-zero on any failure.
`e2e`/`all` refuse to run without `LMNSQUID_ALLOW_REAL=1` (a guard so heavy suites
never fire by accident on the dev box).

> The `scripts/tests/run.sh` aggregator and `crabbox_bootstrap.sh` are the
> established entry points. Wire new heavy tests into that aggregator rather
> than one-off scripts.

## What the heavy E2E must actually prove

The compose stack has four services on a user-defined bridge with static IPs:
`samba-dc` (KDC + AD LDAP + internal DNS), `squid` (the image under test, DNS →
samba-dc), `origin` (nginx returning 200 for the allowed target), `test-client`
(krb5-user + curl). Fixtures on the DC: users `teacher1`/`student1`/`squidsvc`,
group `teachers` with `teacher1`, SPN `HTTP/squid.<realm>` on `squidsvc`, keytab
exported via `samba-tool domain exportkeytab`. The client `/etc/krb5.conf` sets
`dns_canonicalize_hostname=false` + `rdns=false` and `KRB5CCNAME=FILE:/tmp/cc`.

Assertions (driven from `test-client`, `P=http://squid.<realm>:3128`):

- **Teacher ALLOWED → 200:** `kinit teacher1`; `curl -s -o /dev/null -w '%{http_code}' --proxy $P --proxy-negotiate -U : http://origin.<realm>/` == `200`.
- **Student DENIED (authN ok, authZ fail) → 403** (NOT 407): same with `student1` == `403`.
- **Blocked domain DENIED → 403:** teacher to a `blocked.domains` entry == `403`.
- **No ticket → 407** (proves auth is really enforced): `kdestroy`; request == `407`.

The 403-vs-407 split is what makes this a genuine PROOF: 200 = authN+authZ pass;
403 (student) = authenticated but group-denied; 403 (blocked) = policy ACL denied;
407 (no ticket) = auth enforced, not an allow-all fluke. Assert on `%{http_code}`,
not curl exit status. Later phases add HTTPS SNI cases, the 2-school matrix, the
update/rollback scenario (good image vs. deliberately-broken image → auto-rollback),
and the `apt install ./linuxmuster-squid_*.deb` → API/CLI smoke.

## Pitfalls (keep them true or the E2E breaks)

- **Privileged containers:** a real Samba AD DC needs `privileged: true` or elevated
  caps (NET_ADMIN, SYS_TIME) and ports 88/389/53 — some restricted runners forbid
  this. crabbox's full VM handles it; a locked-down CI runner may not.
- **DNS/SPN canonicalization is the flakiest part.** With Kerberos defaults, GSSAPI
  does reverse DNS and the compose PTR won't match the AD FQDN → SPN mismatch. Fix:
  `rdns=false` + `dns_canonicalize_hostname=false` on the CLIENT and the exact FQDN
  that is in the keytab; the squid container must use samba-dc as its DNS resolver
  (static IPs + explicit A record), not Docker embedded DNS.
- **CCACHE type:** kernel-keyring ccache fails in unprivileged containers — set
  `KRB5CCNAME=FILE:...` in the test-client too, or curl silently sends no creds → 407.
- **Password complexity:** set `NOCOMPLEXITY=true` (or `samba-tool domain
  passwordsettings set --complexity=off`) or scripted user creation fails.
- **Fresh state each run:** use a fresh volume for `/var/lib/samba` so provisioning
  is reproducible; add an explicit readiness wait (provision + KDC start ~30–90 s).
- **Provider template:** Proxmox template needs DHCP + cloud-init + `ciuser=crabbox`
  (`9400`=ubuntu). Static-IP/no-cloud-init template → warmup can't SSH in.
  `crabbox doctor` green does NOT prove this.
- **Lease sequentially** and keep every crabbox call `timeout`-bounded.

## Rules

- **A box that fails sync sanity is not a debugging target.** Stop it, warm a fresh
  one, rerun.
- **Never claim a suite is green unless it actually passed** — report the `run.sh`
  summary line verbatim; treat SKIP as "not verified", not "ok".
- `crabbox warmup`/`run`/`status`/`list`/`connect`/`ssh`/`doctor`/`stop`/`cleanup`
  are pre-approved; `prewarm`/`job` provision/cost → ask first.
- Always `crabbox stop <slug>` (or rely on the 30 m idle timeout) so VMs don't linger.
