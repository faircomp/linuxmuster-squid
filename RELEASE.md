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
  a **merged Renovate PR** (`automerge:false`), never automatically.
- **`.deb` (control-plane tooling):** built by CI (`build-deb.yml`) on every `v*` tag and
  attached to the GitHub Release (`gh release download … && apt install ./linuxmuster-squid_*.deb`);
  build locally with `sudo VERSION=<x.y.z> bash packaging/build-deb.sh`. An
  `apt install` of the new `.deb` **automatically restarts the service** (postinst `try-restart`),
  so that the new code is actually loaded (E2E-verified via `deb_smoke.sh`). ⏸ Signing:
  see `packaging/build-deb.sh` (GPG key / lmn73 repo `Release` signature).
- **Git tag** `vX.Y.Z` only once the §0.1 acceptance criteria are met.

## Ongoing releases

Code + docs in the same commit (Conventional Commits) → push → CI green → tag → update the
image/`.deb` digest in the docs.
