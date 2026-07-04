<!--
SPDX-FileCopyrightText: Kevin Stenzel

SPDX-License-Identifier: GPL-3.0-or-later
-->

# CLAUDE.md

## Project overview

**linuxmuster-squid** is a containerized, multi-instance-capable
**Squid proxy for linuxmuster.net 7** (Ubuntu 24.04 / Samba AD): an explicit
forward proxy with **Kerberos SSO** and **AD group ACLs** (teachers/students),
one isolated instance per **(school × role)**, managed via a
**REST API + CLI**. The architecture lives in [`docs/architecture.md`](docs/architecture.md), the security
assumptions in [`docs/threat-model.md`](docs/threat-model.md), the decisions in
[`docs/decisions.md`](docs/decisions.md), the test strategy in
[`docs/test-strategy.md`](docs/test-strategy.md).

| Component | Path | Stack |
|---|---|---|
| Data-plane image (Squid) | `image/` | Ubuntu 24.04 · **`squid-openssl`** · Kerberos/LDAP helpers · envsubst entrypoint |
| Control plane (REST API) | `controlplane/` | Python · FastAPI · uvicorn · **docker-py** (container lifecycle) |
| CLI | `cli/` | Python · Typer · httpx (thin client of the REST API) |
| E2E / Deploy | `deploy/` | docker-compose (Samba AD DC + Squid + client), instance definitions |
| Packaging | `packaging/debian/` | `.deb` via dh-virtualenv, hardened systemd service (lmn73 layout) |
| Tests | `scripts/tests/` | `run.sh` aggregator; heavy tier on **crabbox** |

> **The stack is deliberately Python** (linuxmuster-api7/webui7 are likewise FastAPI/
> Python) — set as the default, overridable (see the ADR in `docs/decisions.md`).

**Security pitfalls (from the threat model — do not violate):**

- **Explicit forward proxy, never transparent/intercept.** In intercept mode Squid
  can do **no** proxy auth (HTTP 407) — Kerberos/Negotiate is tied to the
  TCP connection. Whoever wants identity/group policy must be explicit.
- **No HTTPS decryption.** Only SNI peek/**splice** or CONNECT
  `dstdomain`. The peek CA is **never** distributed to clients. No MITM/SSL bump
  without an explicit, data-protection-approved decision.
- **Keytab = domain credential.** As a secret (tmpfs, `:ro`), readable only by
  `cache_effective_user proxy`, `0600` on the host, separated per instance, never
  in the env, never in the log.
- **Security is enforced by the group ACL, not the GPO.** The GPO only controls which
  proxy a client uses by default; a student at the teacher proxy is rejected (403)
  by `ext_kerberos_ldap_group_acl` despite a valid ticket. Steering
  and enforcement must use the same group names.
- **Multischool prefix rule:** default-school groups are unprefixed
  (`teachers`), all others `<school>-teachers`. Never hardcode — realm,
  base DN, group names, subnets, ports, image digest are **parameterized**.
- **Docker socket access = root-equivalent.** Never expose the control plane beyond
  localhost/the mgmt network; behind a socket proxy/rootless Docker;
  token/TLS; no `0.0.0.0` bind.

---

## 1. Way of working & mindset

Behave like a senior software engineer with 15+ years of experience in
Python, Linux network services, Squid/proxying, Active Directory/Kerberos,
Docker, and the secure operation of school/network infrastructure.

### Before the code

- **Think first, then code.** For non-trivial changes, present a plan,
  make assumptions explicit, name trade-offs, wait for confirmation.
  Typos/style fixes do not need this.
- **Raise ambiguity, do not decide silently.** Several plausible
  interpretations → name them all, do not secretly pick one.
- **Root cause before symptom.** No workarounds that merely shift the problem.
- **YAGNI rigorously.** No prophylactic abstractions. Build the thin, maintainable
  version. Test: would a senior call it "overengineered"? Then simplify.
- **Validation only at boundaries.** Validate uploads/requests, tokens, LDAP responses,
  env/config; internal function calls not.

### During implementation (surgical changes)

- **Only touch what is necessary.** Do not "improve" adjacent code/comments/formatting.
  Do not refactor what is not broken. Match the existing style.
- **Clean up orphans that YOUR change creates** (unused imports/variables).
  Remove pre-existing dead code only when told to — otherwise mention it, do not delete it.
- **Every changed line must be traceable to the task.**

### For external APIs, formats, and docs — VERIFY

- **Verify instead of fabricate.** Whatever is not 100% backed by the official docs,
  mark explicitly as "not verified". Concretely: before you
  implement any Squid/Kerberos/LDAP/config behavior, pull the current docs with `WebFetch`
  — above all the **Squid wiki** (`negotiate_kerberos_auth`,
  `ext_kerberos_ldap_group_acl`, `ssl_bump`/peek-splice, `external_acl_type`),
  the **Samba wiki** (keytab export, `samba-tool spn/exportkeytab`, GC ports),
  **docs.linuxmuster.net** (Sophomorix roles/groups, multischool, exam mode),
  **MIT Kerberos** (SPN/DNS canonicalization, `rdns`), **Microsoft/Mozilla**
  (GPO proxy/zones, Firefox policies) — even if the same info appears to be here or in the code.
  Already-checked facts, including their sources, are in
  `docs/references.md`.
- **Third-party sources (blogs/forums) are a hint, not a substitute** for the official docs.

### Goals, tests & definition of done

- **Translate every task into a verifiable goal** ("add validation"
  → "test for invalid inputs, then green"; "fix bug" → "reproducing test,
  then green").
- **New function/new flow ⇒ a test for it (mandatory).** Pure logic → unit test
  (`pytest`); a new/changed **auth/filter/lifecycle journey** → E2E on
  crabbox (real Kerberos `curl --proxy-negotiate` through the container). No
  "I'll test it later".
- **Negative tests are mandatory.** The catalog in `docs/test-strategy.md` grows per
  roadmap phase (407 without ticket, 403 student/blocked, bypass, traversal,
  ACL misconfig, keytab perms, auth-off, API 401/403).
- **For multi-step tasks, show a short plan _step → verification_.**
- **Before "done", run all checks for real** (only what exists):
  - **Python (`controlplane/`, `cli/`):** `ruff check`, `ruff format --check`,
    `mypy`, `pytest`. Aggregate target: `bash scripts/tests/run.sh quick`.
  - **Shell (`image/*.sh`, `scripts/`):** `shellcheck`.
  - **Squid config:** `squid -k parse` (in the container; green only with `squid-openssl`
    when `ssl_bump` is active).
  - **Heavy tier / E2E:** on **crabbox** (Docker required) — see below.
- **Run relevant tests routinely, do not claim them.** The Docker/
  Kerberos E2E runs on **crabbox** (the dev box has no Docker): keep the box warm,
  after changes to image/auth/filter/lifecycle run
  `LMNSQUID_ALLOW_REAL=1 bash scripts/tests/run.sh e2e` there and report the
  summary.
- **Monitor CI after triggering it** (`gh run watch`), report the result,
  re-run transient failures deliberately. Not "done" while CI is running/red.

### Communication

- **Direct and short.** Honest about limits ("not verified", "assumption").
- **Push back when necessary** (scope creep, undermining an ADR).
- **Interpret user voice input charitably** (dictation recognition errors →
  respond to the intent).
- **Recommendations with rationale** ("recommendation X, because Y; trade-off Z").
- **Language: German**, technical terms and code identifiers in the original.

### Code conventions

- **Conventional Commits** (`feat:`/`fix:`/`chore:`/`refactor:`/`docs:`/`test:`/
  `perf:`), one commit per logical step; messages in English; tags `vX.Y.Z`.
- **Python:** `ruff` (lint+format) + `mypy` clean; type annotations at public
  boundaries; `pydantic` for models/config; no silent `except:`.
- **Security in the code:** **never log** secrets/tokens/keytabs; token comparisons
  constant-time (`hmac.compare_digest`); `HTTPBearer(auto_error=False)`; Docker
  only via the one audited service path (docker-py), never directly from the CLI.
- **SPDX header & license:** `GPL-3.0-or-later`, © Kevin Stenzel. Every new
  source file gets the REUSE header (`# ` for Python/Shell/YAML, `<!-- -->` for
  Markdown) — e.g. `reuse annotate --copyright "Kevin Stenzel" --license GPL-3.0-or-later <file>`.
- **Comments only when the why is not obvious** (hidden
  constraints, Kerberos/DNS pitfalls, workarounds). The WHAT is in the code.

### Docs maintenance

A code change without a matching docs update counts as incomplete. Before "done", check:
`docs/architecture.md`, `docs/threat-model.md`, `docs/test-strategy.md`,
`docs/decisions.md` (ADRs), `README.md`, `CHANGELOG.md` (from the first version onward). The docs update belongs
in **the same commit** as the code change. Wrong docs are a bug —
fix them, even if not directly part of the change.

## 2. Testing on crabbox (heavy tier)

The dev box only edits + orchestrates — it has **no Docker**. The fast
tier (ruff/mypy/pytest/shellcheck) runs locally/in CI. The **heavy tier** — the
real docker-compose Kerberos E2E (**Samba AD DC + Squid + client**) that proves
*teacher→200 / student→403 / blocked→403 / no-ticket→407*, as well as multischool,
update/rollback, and `.deb` install tests — needs real Linux with **Docker**.
**crabbox** leases an ephemeral Proxmox VM for this (provider in
`.claude/settings.json`, token only in the gitignored `.claude/settings.local.json`;
`crabbox doctor`). Rules/details: the `/test` skill (`.claude/skills/test/SKILL.md`).

- **One aggregate runner:** `bash scripts/tests/run.sh [lint|unit|quick|e2e|all]`
  (created in P0/P1). `quick` (default) = lint + unit; `e2e`/`all` run the
  Docker suites and **refuse without `LMNSQUID_ALLOW_REAL=1`**. Summary:
  `N passed, M failed, K skipped` (exit ≠ 0 on failure); steps dep-gated.
- **Box lifecycle:** `crabbox warmup` → `crabbox run --id <slug> -- 'bash scripts/tests/crabbox_bootstrap.sh'`
  → `crabbox run --id <slug> -- 'LMNSQUID_ALLOW_REAL=1 bash scripts/tests/run.sh e2e'`
  → `crabbox stop --id <slug>`.
- **Never report "green" without the suite having really passed** — the
  `run.sh` summary is what counts; SKIP means "not verified", not "ok".
- `crabbox warmup`/`run`/`status`/`list`/`connect`/`ssh`/`doctor`/`stop`/`cleanup`
  are pre-approved; `prewarm`/`job` provision/cost → ask first.
- Always `crabbox stop <slug>` (or the 30-min idle timeout), so that no VMs linger.
