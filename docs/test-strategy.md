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
  (control-plane logic, API handlers with the httpx TestClient, CLI client).
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
| Blocked domain | Teacher → entry from `blocked.domains` | **403** |
| No ticket | `kdestroy`; request | **407** |

The 403-vs-407 split is the actual proof (authenticated-but-unauthorized
vs. not-authenticated).

## Negative/security catalog (grows per phase; part of the DoD)

- **P1:** no ticket→407; student→403; SPN mismatch/FQDN-as-IP → no 200.
- **P2:** blocked HTTPS domain (SNI/CONNECT)→403 **without** client CA; allowed→200;
  behavior on missing SNI defined.
- **P3:** teacher of school A via school-B instance→403; prefixed group names take effect;
  subnet scope takes effect.
- **P4:** API without token→401, wrong token→403; invalid instance definition
  rejected; reconcile idempotent.
- **P5:** update to a broken image→auto-rollback, service stays available;
  `rollback` deterministic.
- **P9:** `.deb` install→systemd `active`, API/CLI smoke; package upgrade/rollback.
- **P10:** keytab perms; manager ACL not reachable externally; API bind ≠ 0.0.0.0;
  bypass/traversal; DC outage does not stall (ttl/grace).

## Rules

- **New/changed auth/filter/lifecycle journey ⇒ add an E2E case** (mandatory,
  part of "done").
- **Never claim "green" without a real run** — cite the `run.sh` summary; SKIP =
  "not verified".
- Assertions on plain-HTTP targets (proxy status visible inline in `%{http_code}`);
  for HTTPS CONNECT cases, mind the exit-code/header semantics.
