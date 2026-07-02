---
name: advance-roadmap
description: Advance ROADMAP.md by exactly one iteration — implement the next open task(s) of the current phase up to the next verification gate, verify for real, check off, update the status pointer, and commit. Built to be run under /loop for an autonomous, resumable buildout of linuxmuster-squid. State lives in ROADMAP.md + git, so it survives context resets. Pauses at human gates instead of guessing.
---

# /advance-roadmap — eine Roadmap-Iteration

Führt **genau eine Iteration** der `ROADMAP.md` aus. Gedacht für `/loop
/advance-roadmap`: bei jedem Aufruf ein Chunk Arbeit bis zum nächsten
Verifikations-Gate — kein Häkchen ohne realen Test, Pause an jedem menschlichen Gate.

**Single Source of Truth ist das Repo, nicht dieser Chat:** die Checkboxen
(`[ ]`/`[x]`) in `ROADMAP.md`, die „**Aktueller Stand**"-Zeile oben, die git-History.
Jede Iteration liest den Stand frisch aus `ROADMAP.md`. So ist Fortsetzen nach
Unterbrechung/Context-Reset trivial.

## 0 · Vorbedingungen (nur beim allerersten Lauf prüfen)

- Ist `.` ein git-Repo? Falls nein: `git init`, Arbeitsbranch anlegen
  (`git switch -c build/roadmap`), Erstzustand committen. **Nie auf `main` bauen.**
- Sind die `Assumed`/offenen ADRs in `docs/decisions.md` entschieden? Falls ein
  **blockierender** Fork offen ist (Stack, Netzmodell, Keytab-Quelle, Registry,
  Lizenz) → **PAUSE**, den Nutzer fragen, erst dann weiter.
- `CLAUDE.md` gelesen (Arbeitsweise, Sicherheits-Stolperfallen)?

## 1 · Zustand lesen

`ROADMAP.md` öffnen. Aus der „Aktueller Stand"-Zeile die **aktuelle Phase**
bestimmen; darin die **erste offene Aufgabe** `[ ]` wählen. Phasen-Reihenfolge
strikt einhalten — nie vorgreifen.

## 2 · Umsetzen (chirurgisch)

Die Aufgabe umsetzen, nur was sie verlangt (siehe `CLAUDE.md` → Surgical Changes).
Bei nicht-trivialen/mehrdeutigen Aufgaben zuerst kurz `Schritt → Verifikation`
skizzieren. Verifizieren statt raten: vor Squid-/Kerberos-/LDAP-/GPO-Config die
offizielle Doku ziehen.

## 3 · Verifizieren — schneller Tier (jede Aufgabe, lokal)

Nur ausführen, was real existiert:
- Python: `ruff check`, `ruff format --check`, `mypy`, `pytest`
- Shell: `shellcheck`
- Squid-Config: `squid -k parse` (im Container)

Sammel: `bash scripts/tests/run.sh quick`. **Rot → fixen, NICHT abhaken.**

## 4 · Abhaken & committen

Erst wenn der schnelle Tier grün ist: Häkchen `[x]` setzen, betroffene Doku im
**selben Commit** pflegen (`docs/`, `README.md`, ADRs), Conventional-Commit
(`feat:`/`fix:`/`test:`/`docs:` …), ein Commit pro logischem Schritt.

Weitere offene Aufgaben in der Phase? → zurück zu Schritt 2.

## 5 · Phasen-Gate — schwerer Tier (crabbox), nur wenn Phase leer

Sind **alle** Aufgaben der Phase `[x]`, die **Definition of Done** der Phase über
den schweren Tier beweisen (Kerberos-E2E etc.) — siehe die **`/test`-Skill**:
- Box **warm-once**, Slug in `.crabbox/active-slug` (gitignored) merken und
  wiederverwenden; nicht pro Iteration warm/stop.
- E2E als **Hintergrund-Job** starten (Warmup+Bootstrap+E2E dauern Minuten) →
  Wiederaufruf bei Fertigstellung; als Fallback einen langen `ScheduleWakeup`
  (~1200 s) setzen, falls der Lauf hängt.
- **Grün** (`run.sh`-Summary `N passed, 0 failed`)? → „Aktueller Stand"-Zeile auf
  die **nächste Phase** setzen, committen.
- **Rot?** → Fehler beheben (in dieser Phase bleiben), **nicht** vorrücken.
- Am Ende/Idle `crabbox stop`. `prewarm`/`job` kosten → vorher fragen.

## 6 · Menschliche Gates → PAUSE + fragen (nicht raten, nicht faken)

Hier anhalten und den Nutzer einbeziehen:
- offene/`Assumed`-ADRs, die eine Aufgabe blockieren;
- **P0-Verifikation am echten DC** (reales Realm/Base DN, Gruppen-DN via
  `ldbsearch`, `%u`/`%v`) — echte Site-Daten;
- **P8-Produktiv-Abnahme** auf echten Windows-Clients (nicht automatisierbar →
  Vorlagen + Checkliste bereitstellen und „bereit zur Abnahme" melden);
- **Renovate-PR-Merge** (Update-Go/No-Go), **Release-Push/Tag**;
- alles, was echte Zugangsdaten/Infrastruktur außerhalb des Repos braucht.

## 7 · Fortsetzen oder beenden

- Menschliches Gate erreicht → **PAUSE**, klar berichten was ansteht.
- Alle Phasen bis **P10** `[x]` **und** alle Abnahmekriterien in `ROADMAP.md`
  §0.1 real bewiesen → **Loop beenden** (Release `v1.0.0`).
- Sonst → nächste Iteration (der `/loop`-Rahmen ruft erneut auf).

## Guardrails (nicht verhandelbar)

- **Kein `[x]` ohne bestandenen realen Test.** „SKIP" heißt „nicht verifiziert",
  nicht „ok". Test-Summaries zitieren, nie behaupten.
- **Bei Blockade/Mehrdeutigkeit: PAUSE + fragen**, nicht heimlich entscheiden.
- **Verifikation nach 2–3 Fixversuchen weiter rot → stoppen und berichten**, nicht
  im Kreis drehen.
- Sicherheits-Stolperfallen aus `CLAUDE.md`/`docs/threat-model.md` nie verletzen
  (expliziter Proxy, keine HTTPS-Entschlüsselung, Keytab-Handling, ACL erzwingt
  Sicherheit, Docker-Socket = root-äquivalent, nichts hartkodieren).
- Nach jeder Iteration eine kurze Status-Zeile ausgeben (Phase, erledigte Aufgabe,
  Testergebnis, nächster Schritt).
