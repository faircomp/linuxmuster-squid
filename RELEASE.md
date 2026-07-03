<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Release & Image-Bootstrap

Bis das Data-Plane-Image **einmal publiziert** ist, existiert `ghcr.io/faircomp/linuxmuster-squid`
noch nicht — jede `lmnsquid create --image ghcr.io/…@sha256:<digest>`-Zeile in der Doku ist ein
**Platzhalter**. Dieser Ablauf schließt die Lücke. ⏸ = braucht dich (Human-Gate).

## Erstveröffentlichung (einmalig)

1. ⏸ **GitHub-Remote anlegen + pushen.** Ohne Remote lief `.github/workflows/build-image.yml`
   nie → kein Image, kein echter Digest.
   ```
   git remote add origin git@github.com:faircomp/linuxmuster-squid.git
   git push -u origin build/roadmap        # bzw. nach main mergen
   ```
2. ⏸ **CI beobachten:** `gh run watch` — `build-image.yml` baut das Image und pusht es nach GHCR
   (`ghcr.io/<owner>/linuxmuster-squid`). Transiente Fehler gezielt re-runnen.
3. ⏸ **GHCR-Package sichtbar machen:** im GitHub-Package-UI auf **public** stellen — sonst brauchen
   die Proxy-Hosts ein `docker login ghcr.io` / einen Pull-Token.
4. **Digest festhalten:** den publizierten `@sha256:…` in `docs/operations.md` (und die
   `deploy/instances/*.yaml`-Beispiele) eintragen — statt der `<digest>`-Platzhalter.
   ```
   docker buildx imagetools inspect ghcr.io/faircomp/linuxmuster-squid:<tag>   # zeigt den Digest
   ```

## Versionen & Tags

- **Data-Plane-Image:** wird von der CI je Push/Tag gebaut; **produktiv nur per `@sha256`-Digest**
  referenzieren (die Instanz-Validierung erzwingt Tag/Digest). Welcher Digest live geht, entscheidet
  ein **gemergter Renovate-PR** (`automerge:false`), nie automatisch.
- **`.deb` (Control-Plane-Tooling):** `sudo VERSION=<x.y.z> bash packaging/build-deb.sh`. Ein
  `apt install` des neuen `.deb` **startet den Dienst automatisch neu** (postinst `try-restart`),
  sodass der neue Code wirklich geladen wird (crabbox-verifiziert via `deb_smoke.sh`). ⏸ Signierung:
  siehe `packaging/build-deb.sh` (GPG-Key / lmn73-Repo-`Release`-Signatur).
- **Git-Tag** `vX.Y.Z` erst, wenn die §0.1-Abnahmekriterien (ROADMAP) erfüllt sind.

## Laufende Releases

Code + Doku im selben Commit (Conventional Commits) → push → CI grün → Tag → Image/`.deb`-Digest
in der Doku aktualisieren.
