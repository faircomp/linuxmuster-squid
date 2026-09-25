<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Test Strategy — linuxmuster-squid

Two tiers. The **fast tier** runs locally/in CI; the **heavy tier** (Docker +
Kerberos) runs on a **Linux host with Docker**. Aggregator:
`bash scripts/tests/run.sh [lint|unit|quick|e2e|all]` — summary
`N passed, M failed, K skipped`, exit ≠ 0 on failure, every step dep-gated.
`e2e`/`all` refuse to run without `LMNSQUID_ALLOW_REAL=1`.

## Fast tier (everywhere)

- **Python:** `ruff check`, `ruff format --check`, `mypy`, `pytest`
  (control-plane logic, API handlers with the httpx TestClient, CLI client). CI runs them
  against the locked dependency versions the `.deb` ships (`controlplane/requirements.lock`).
- **Lock files:** `bash packaging/lock-deps.sh --gate`, the first step of the fast tier and of
  every package build (`packaging/build-venv.sh`), before anything from a lock is installed
  anywhere: every line is one uv writes; `packaging/requirements-uv.lock` pins uv and nothing
  else, with hashes PyPI publishes and older than 7 days (standard library only); with that
  uv, installed into a venv of its own and run by absolute path, every hash of the three locks
  is one PyPI publishes for exactly that `name==version`, the pins are exactly the closure of
  `controlplane/pyproject.toml` and the `.in` files within the 7-day cutoff, every pin has a
  CPython 3.12 manylinux x86_64 wheel, and the header is the canonical command. No program,
  interpreter or `bin/` of a venv filled from a lock runs or is on PATH before that, whatever
  shell it is started from (fixed PATH, `/usr/bin/python3 -I`, the caller's venv, `PYTHON*`,
  `UV_*`, `PIP_*` and `GIT_*` settings removed: `packaging/clean-env.sh`). After
  installing, the build venv must be exactly the build lock plus ensurepip's pip and the
  shipped venv exactly the lock plus lmnsquid, every line `name==version` (`--verify-freeze`).
  `bash scripts/tests/lock_gates.sh` keeps the manipulations of the cold verifications
  rejected for good, each for its own reason: an indented `name @ url#sha256=` line,
  `--extra-index-url`, a pin's hashes removed, a changed hash (the wheel's and the sdist's),
  an extra pin with valid hashes, a pin without hash, in the locks where it matters; for the
  uv lock an extra pin, a changed hash, a foreign package and a uv younger than 7 days; and
  the K1 wheel, with its own `diff`, `comm`, `sort`, `awk`, `grep`, `cut`, `cp`, `python3`,
  `uv`, `pip` and 34 more tools in `bin/` (each checked to be installed executable and to run)
  and a marker-writing `.pth`, "published" with its real hash by a local PEP 691 index (the
  copy's gate asks that index: one line of `lock-deps.sh` changed, nothing in the environment),
  in the build lock alone and in both locks: only the closure check can stop it, and nothing of
  it may run (no marker). The same wheel as an activated venv of the caller (PATH,
  `VIRTUAL_ENV`, `CONDA_PREFIX`, `UV_PYTHON`, a `PYTHONPATH` with its own `venv` module) and as
  `.venv/` in the checkout: the gate still rejects a real extra pin and passes the committed
  locks without a marker, `run.sh quick` stops at the gate before any `.venv` tool runs; the
  counter-proof (the gate without its fixed PATH and clean environment) sees the wheel's tools
  run. `--verify-freeze` must reject a direct-URL, editable, extra, missing or re-versioned
  package. CI also runs `lock_gates.sh --build`: every lock case through `make deb`, also from
  the poisoned shell, which must stop in the gate before any venv of the build exists, without
  a .deb and without a marker; its counter-proof (the gate switched off in the build) sees the
  wheel's `bin/pip` run.
- **`make deb`:** `scripts/tests/make_deb.sh` (CI, as root in the build image): a git worktree
  of a repository owned by another user, with umask-002 modes, a lost x bit, secrets, venvs and
  junk, and git configuration that runs programs (fsmonitor, filters, textconv, hooks), built
  from the poisoned shell, gives byte-for-byte the `.deb`, `.dsc` and source tarball of the
  package job; the tarball holds exactly the tracked files (without `.github/`, `.claude/`,
  `.gitignore`) with git's modes, and nothing of the traps or the shell ran (counter-proof:
  `git status` there does run them). A dirty tree (modified, deleted, staged, new) is built as
  it is and named in a warning with the version; a tracked symlink stays a symlink; a worktree
  whose repository is not reachable, or whose repository names another working tree, stops the
  build and writes nothing; a tree without `.git` is built as it is.
- **Shell:** `shellcheck` for `image/*.sh`, `scripts/**`.
- **Squid config:** `squid -k parse` against rendered templates (in the container;
  green only with `squid-openssl` once `ssl_bump` is active).

## Heavy tier — Kerberos E2E (Docker)

docker-compose stack: `samba-dc` + `squid` + `origin` + `test-client` (details in
the `/test` skill). **Core proof** (P1), assertions on `%{http_code}`:

| Case | Action | Expectation |
|---|---|---|
| Teacher allowed | `kinit teacher1`; via teacher instance | **200** |
| Student denied (authN ok, authZ fail) | `kinit student1`; via teacher instance | **403** (not 407) |
| Blocked domain (HTTP) | Teacher → entry from `blocked.domains` | **403** |
| Blocked domain (HTTPS) | Teacher → CONNECT to a blocked name | **not 200**: TLS handshake terminated (curl exit ≠ 0), no 403 page |
| No ticket | `kdestroy`; request | **407** |

The 403-vs-407 split is the actual proof (authenticated-but-unauthorized
vs. not-authenticated). The compose stack bind-mounts `deploy/e2e/blocked.domains`; the
**product path** (`lmnsquid blocklist <name> add … && … reload` on a managed instance →
403) is proven against a real domain in the lab (7.3.1 campaign fix) and is part of the
acceptance list in `deployment-gpo.md`.

## Negative/security catalog (grows per phase; part of the DoD)

- **P1:** no ticket→407; student→403; SPN mismatch/FQDN-as-IP → no 200.
- **P2:** blocked HTTPS domain (SNI/CONNECT)→TLS handshake terminated, never 200,
  **without** client CA; allowed→200; behavior on missing SNI defined.
- **P3:** teacher of school A via school-B instance→403; prefixed group names take effect;
  subnet scope takes effect.
- **P4:** API without token→401, wrong token→403; invalid instance definition
  rejected; reconcile idempotent (matching container untouched); one instance failing to
  come up does not block the others (`failed` list) and the previous container is kept.
- **P5:** update to a broken image→auto-rollback, service stays available;
  `rollback` deterministic.
- **P9:** `.deb` install→systemd `active`, API/CLI smoke; package upgrade/rollback;
  the same `.deb` configured 30 times in a row (`scripts/tests/install_loop.sh`, CI
  install-smoke: 15× purge + fresh install, 15× reinstall/`dpkg-reconfigure`, stop at the
  first failure) — an intermittent postinst race (7.3.1–7.3.3) passed single installs;
  upgrade over a release with root-owned files in the change log repository → handed
  back to `lmnsquid`, history kept.
- **P10:** keytab perms; manager ACL not reachable externally; API bind ≠ 0.0.0.0;
  bypass/traversal; DC outage does not stall (ttl/grace).

## Rules

- **New/changed auth/filter/lifecycle journey ⇒ add an E2E case** (mandatory,
  part of "done").
- **Never claim "green" without a real run** — cite the `run.sh` summary; SKIP =
  "not verified".
- Assertions on plain-HTTP targets (proxy status visible inline in `%{http_code}`);
  for HTTPS CONNECT cases, mind the exit-code/header semantics.
