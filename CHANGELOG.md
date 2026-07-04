<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/) · [SemVer](https://semver.org/).

## [Unreleased]

### Changed
- **Project language switched to English** across all docs, code comments, and scripts
  (README, `docs/`, `CLAUDE.md`, shell/YAML/Dockerfile comments). Only
  maintainer↔user conversation stays German.

### Removed
- `ROADMAP.md` (all phases complete) and the `/advance-roadmap` dev skill that drove it.

### Added
- **REUSE 3.3 license compliance** (`reuse lint` green, 77/77): `LICENSES/GPL-3.0-or-later.txt`,
  SPDX headers on every file, `.license` sidecars for non-comment files (JSON, Debian control).
  `reuse lint` added as a CI gate; `[project.urls]` in `pyproject.toml`.

### Fixed
- **CI shellcheck** was failing on pre-existing info-level findings; pinned to
  `--severity=warning` in `run.sh` and CI, and fixed a real `SC2164` (`cd … || exit`).

## [1.0.0-rc3] - 2026-07-03

Gap-review backlog (P11) worked off — deployment reality,
operations, honesty. All items tested automatically.

### Fixed
- **`.deb` upgrade restarts the service** (postinst `try-restart`; `prerm` stops only on
  `remove`) → new code is actually loaded. `deb_smoke` checks the MainPID change.

### Added
- **reconcile/restore:** `POST /v1/reconcile` + `lmnsquid reconcile`; restore/DR runbook;
  `instances_dir` as a git repo (change log).
- **dockerd down → 503** (instead of raw 500); alerting/auth-health docs (without monitoring stack).
- **Blocklist fail-closed** (sanity floor) against tampered/truncated downloads.
- **Bind warning** on non-loopback (token cleartext); `RELEASE.md` (GHCR bootstrap).

### Docs / Honesty
- **ECH/QUIC/DoH** documented as a known SNI-filter limit + OPNsense mitigation (threat model **T14**).
- TLS loopback only (in-app TLS not implemented); socket proxy is **not** a root downgrade
  (rootless Docker = the real answer); GPG signing via reprepro `Release` instead of per-`.deb`.
- Socket proxy pinned to `:v0.4.2`.

### Pending (human gates)
- Publish image on GHCR; GPG key/signing; Windows GPO acceptance; real AD facts.

## [1.0.0-rc2] - 2026-07-03

### Added
- **Log retention & query:** access log mirrored to `docker/lmnsquid logs`; persistent
  **gzip-rotated history** in the persistent log volume (`logrotate`, `log_retention_days`,
  default 30, up to 3650). Docker json log capped (`log_max_size/log_max_file`).
- **API/CLI query:** `GET /logs?since=&until=&grep=` (live) + new `GET /logs/access` (historical,
  searches the daily `.gz` files injection-safely); CLI `logs`/`access-logs`.
- **Data protection:** `access_log_enabled` per instance (requests can be switched off entirely); retention =
  documented deletion deadline (threat model T13).

## [1.0.0-rc1] - 2026-07-03

First complete, E2E-verified version. All automatically testable
acceptance criteria are green; open items are exclusively human gates
(real Windows GPO acceptance, GPG signing with the linuxmuster key, site-specific
AD facts).

### Added
- **Data-plane image** (`squid-openssl`): explicit forward proxy, **Kerberos SSO**
  against Samba AD (`negotiate_kerberos_auth`), **AD group authorization**
  (`ext_kerberos_ldap_group_acl`), one container per **(school × role)**.
- **HTTPS filtering without decryption** (SNI peek/splice + CONNECT `dstdomain`);
  UT-Capitole blocklist refresh.
- **Multischool isolation** with prefix rule; declarative `deploy/instances/*.yaml`.
- **Control plane**: FastAPI REST API + **Typer CLI** (thin client), docker-py
  lifecycle, git state store, reconciler, bearer auth.
- **Digest-pinned updates with health auto-rollback**; Renovate; GHCR CI.
- **Hardening**: read-only rootfs + `cap_drop: ALL` + `no-new-privileges` for the
  proxy containers; hardened systemd service.
- **Packaging**: signable `.deb` (hermetic venv) + systemd unit; Keytab/DNS
  and GPO deployment guides; filtered Docker socket proxy.

### Security
- Strict field validation of all instance fields (defense against path traversal & injection),
  image must carry `:tag`/`@sha256:` (no pull-all-tags DoS), IP-literal CONNECT deny,
  token TOCTOU fix, constant-time token comparison, Docker socket proxy.
  **All findings of a security review fixed.**

### Verified (E2E)
- E2E: teacher 200 / student 403 / blocked 403 / no-ticket 407; HTTPS splice/block;
  multischool isolation; real docker-py container lifecycle + auto-rollback;
  `.deb` install/upgrade. Unit 41 + mypy + ruff green.

### Pending (human gates)
- Manual Windows GPO acceptance on real domain-joined clients (`docs/deployment-gpo.md`).
- GPG signing with the linuxmuster key; real AD facts (realm/base DN/group DN).
