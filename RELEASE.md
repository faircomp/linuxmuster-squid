<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Release & Image Bootstrap

Until the data-plane image has been **published once**, `ghcr.io/faircomp/linuxmuster-squid`
does not yet exist — every `lmnsquid create --image ghcr.io/…@sha256:<digest>` line in the docs is a
**placeholder**. This procedure closes that gap. ⏸ = needs you (human gate).

## Initial publication (one-time)

1. **GitHub remote + push.** The repository lives at
   `github.com/faircomp/linuxmuster-squid`; `main` carries the current tree.
   ```
   git push -u origin main
   ```
   ⏸ Flip the repository to **public** (open-source) in the GitHub settings when ready.
   Until then `.github/workflows/build-image.yml` still runs, but the image/digest is
   only reachable to the org.
2. ⏸ **Watch the CI:** `gh run watch` — `build-image.yml` builds the image and pushes it to GHCR
   (`ghcr.io/<owner>/linuxmuster-squid`). Re-run transient failures selectively.
3. ⏸ **Make the GHCR package visible:** set it to **public** in the GitHub package UI — otherwise
   the proxy hosts need a `docker login ghcr.io` / a pull token.
4. **Record the digest:** enter the published `@sha256:…` in `docs/operations.md` (and the
   `deploy/instances/*.yaml` examples) — replacing the `<digest>` placeholders.
   ```
   docker buildx imagetools inspect ghcr.io/faircomp/linuxmuster-squid:<tag>   # shows the digest
   ```

## Versions & tags

- **Data-plane image:** built by the CI on each push/tag; **reference it in production only via
  `@sha256` digest** (instance validation enforces tag/digest). Which digest goes live is decided by
  a **merged PR** (raised by hand while Renovate is disabled), never automatically.
- **`.deb` (control-plane tooling):** built by CI (`release.yml`) on every `v*` tag — in the
  `ghcr.io/linuxmuster/lmndev-runner:24.04` container (pinned by digest), with the venv's Python
  packages installed only from `controlplane/requirements.lock` (`--require-hashes`),
  install-smoked and upgrade-smoked on
  `ubuntu-24.04` (the upgrade smoke installs the newest published release, gives it an
  admin's config and state and upgrades onto it) — and
  attached to the GitHub Release (`gh release download … && apt install ./linuxmuster-squid_*.deb`).
  The release is created as a **draft**, the `.deb`, the source package (`.dsc`, `.tar.xz`)
  and the `.changes`/`.buildinfo` are uploaded and their SHA-256 compared with the build, and
  only then is it published: GitHub's immutable releases freeze tag and assets at publication.
  The job fails unless the published release reports `immutable: true`. With the optional
  repository secret `IMMUTABLE_CHECK_TOKEN` (fine-grained, this repository only,
  "Administration: Read-only") it also refuses to publish, leaving the draft, while immutable
  releases are off; `GITHUB_TOKEN` cannot read that setting.
  The version is the top entry of `debian/changelog` (`7.3.N`, distribution `lmn73`); the
  workflow refuses a tag that does not match it. Build locally with `make deb`
  (dpkg-buildpackage, which needs no root; in the same container, started as root for
  `apt-get build-dep`: the command is in the `Makefile`). An
  `apt install` of the new `.deb` **automatically restarts the service** (postinst
  `deb-systemd-invoke restart`; a service the admin disabled only while it still runs),
  so that the new code is actually loaded (E2E-verified via `deb_smoke.sh`). Distribution:
  the GitHub release is the only channel for now. ⏸ An apt archive of our own
  (`lmndeb.fair-comp.de`, decided by Kevin) comes later; apt verifies the signed repository
  `Release` (InRelease / Release.gpg) there, not single `.deb` signatures, so no `dpkg-sig` per
  package. The package does not go into deb.linuxmuster.net.
- **Git tag** `v<version>` = the changelog head (`v7.3.0` for `7.3.0`, `v7.3.1-rc1` for
  `7.3.1~rc1`), set by Kevin on `main`; never in a feature PR.

## Ongoing releases

**A release whose `image/` changed pins that image before it is tagged.** The control plane
installs and updates instances with `DEFAULT_IMAGE` (`controlplane/lmnsquid/models.py`); a
changed template that is not pinned never reaches an installed system. Order: merge the change
→ `build-image.yml` builds and pushes it on `main` (the digest is in the job log, "Report
digest") → a PR sets `DEFAULT_IMAGE` to that `@sha256:` digest (by hand while Renovate is
disabled) → CI green → set the changelog version and tag. The package upgrade then moves every
instance onto the new image (`update-all` in the postinst, health-gated with rollback).
**7.3.8** is such a release: the noauth list (ADR-016) and `lists-sync.sh` live in the image;
until the digest is pinned, `lmnsquid noauth <name> reload` answers 409 and the lists still
reach squid unfiltered. The E2E service `squid-old` and the integration test
`test_real_old_image_ignores_the_noauth_list` deliberately keep testing the image 7.3.7 pins
(`…@sha256:d13625b5…`, a constant in `scripts/tests/e2e_kerberos.sh` and
`controlplane/tests/test_docker_integration.py`), i.e. what instances run until the upgrade
replaces their containers; they do not follow `DEFAULT_IMAGE` and need no change for the pin.

Code + docs + a `debian/changelog` bullet in the same commit (Conventional Commits) → push →
CI green (`ci.yml`: fast tier, container build, install smoke, upgrade smoke) → Kevin sets the
release version in the changelog head and tags `v<version>` → `release.yml` builds, smokes and
publishes the GitHub Release with generated notes → update the image/`.deb` digest in the docs.
Build inputs (action SHAs, build-image and base-image digests, the Python lock files, the
Renovate engine) change only through PRs that a human merges; they then ship with the next
release like any other change. The Renovate workflow (`.github/workflows/renovate.yml`) that
proposed them is disabled (Kevin, 2026-09-25) until Renovate returns with a GitHub App; until
then they are raised by hand (`bash packaging/lock-deps.sh` for the locks).
