---
# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

name: advance-roadmap
description: Advance ROADMAP.md by exactly one iteration — implement the next open task(s) of the current phase up to the next verification gate, verify for real, check off, update the status pointer, and commit. Built to be run under /loop for an autonomous, resumable buildout of linuxmuster-squid. State lives in ROADMAP.md + git, so it survives context resets. Pauses at human gates instead of guessing.
---

# /advance-roadmap — one roadmap iteration

Runs **exactly one iteration** of `ROADMAP.md`. Intended for `/loop
/advance-roadmap`: on each invocation, one chunk of work up to the next
verification gate — no checkmark without a real test, pause at every human gate.

**The single source of truth is the repo, not this chat:** the checkboxes
(`[ ]`/`[x]`) in `ROADMAP.md`, the "**Current status**" line at the top, the git history.
Each iteration reads the state fresh from `ROADMAP.md`. This makes resuming after an
interruption/context reset trivial.

## 0 · Preconditions (check only on the very first run)

- Is `.` a git repo? If not: `git init`, create a working branch
  (`git switch -c build/roadmap`), commit the initial state. **Never build on `main`.**
- Are the `Assumed`/open ADRs in `docs/decisions.md` decided? If a
  **blocking** fork is open (stack, network model, keytab source, registry,
  license) → **PAUSE**, ask the user, only then continue.
- Has `CLAUDE.md` been read (way of working, security pitfalls)?

## 1 · Read the state

Open `ROADMAP.md`. From the "Current status" line, determine the **current phase**;
within it, pick the **first open task** `[ ]`. Keep the phase order
strict — never jump ahead.

## 2 · Implement (surgical)

Implement the task, only what it requires (see `CLAUDE.md` → Surgical Changes).
For non-trivial/ambiguous tasks, first briefly sketch `Step → Verification`.
Verify instead of guessing: before any Squid/Kerberos/LDAP/GPO config, pull the
official documentation.

## 3 · Verify — fast tier (every task, local)

Run only what actually exists:
- Python: `ruff check`, `ruff format --check`, `mypy`, `pytest`
- Shell: `shellcheck`
- Squid config: `squid -k parse` (in the container)

Aggregate: `bash scripts/tests/run.sh quick`. **Red → fix, do NOT check off.**

## 4 · Check off & commit

Only once the fast tier is green: set the checkmark `[x]`, maintain the affected docs in
the **same commit** (`docs/`, `README.md`, ADRs), Conventional Commit
(`feat:`/`fix:`/`test:`/`docs:` …), one commit per logical step.

More open tasks in the phase? → back to step 2.

## 5 · Phase gate — heavy tier (crabbox), only when the phase is empty

Once **all** tasks of the phase are `[x]`, prove the phase's **Definition of Done**
via the heavy tier (Kerberos E2E etc.) — see the **`/test` skill**:
- Bring the box up **warm-once**, remember the slug in `.crabbox/active-slug` (gitignored) and
  reuse it; do not warm/stop per iteration.
- Start the E2E as a **background job** (warmup+bootstrap+E2E take minutes) →
  re-invoke on completion; as a fallback, set a long `ScheduleWakeup`
  (~1200 s) in case the run hangs.
- **Green** (`run.sh` summary `N passed, 0 failed`)? → set the "Current status" line to
  the **next phase**, commit.
- **Red?** → fix the errors (stay in this phase), do **not** advance.
- At the end/idle, `crabbox stop`. `prewarm`/`job` cost money → ask first.

## 6 · Human gates → PAUSE + ask (don't guess, don't fake)

Stop here and involve the user:
- open/`Assumed` ADRs that block a task;
- **P0 verification against the real DC** (real realm/base DN, group DN via
  `ldbsearch`, `%u`/`%v`) — real site data;
- **P8 production acceptance** on real Windows clients (not automatable →
  provide templates + checklist and report "ready for acceptance");
- **Renovate PR merge** (update go/no-go), **release push/tag**;
- anything that needs real credentials/infrastructure outside the repo.

## 7 · Continue or finish

- Human gate reached → **PAUSE**, report clearly what is pending.
- All phases through **P10** `[x]` **and** all acceptance criteria in `ROADMAP.md`
  §0.1 really proven → **end the loop** (release `v1.0.0`).
- Otherwise → next iteration (the `/loop` framework invokes again).

## Guardrails (non-negotiable)

- **No `[x]` without a passing real test.** "SKIP" means "not verified",
  not "ok". Quote test summaries, never claim them.
- **On a blocker/ambiguity: PAUSE + ask**, do not decide covertly.
- **Verification still red after 2–3 fix attempts → stop and report**, do not
  spin in circles.
- Never violate the security pitfalls from `CLAUDE.md`/`docs/threat-model.md`
  (explicit proxy, no HTTPS decryption, keytab handling, ACL enforces
  security, Docker socket = root-equivalent, hardcode nothing).
- After each iteration, print a short status line (phase, completed task,
  test result, next step).
