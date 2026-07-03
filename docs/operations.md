<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Betrieb

Kurzreferenz für den laufenden Betrieb. Architektur → [`architecture.md`](architecture.md),
Client-Rollout → [`deployment-gpo.md`](deployment-gpo.md), Keytabs/DNS →
[`keytab-and-dns.md`](keytab-and-dns.md).

## Installation (Control-Plane-Tooling)

```
apt install ./linuxmuster-squid_<version>_all.deb     # bzw. aus dem lmn73-apt-Repo
systemctl status linuxmuster-squid                    # sollte "active" sein
```
Der postinst legt den System-User `lmnsquid` (in Gruppe `docker`) an, generiert einen
zufälligen API-Token in `/etc/linuxmuster-squid/config.yml` (0600) und startet den Dienst
(gebunden an `127.0.0.1:8080`).

## Instanzen verwalten (CLI = dünner Client der REST-API)

> **Tipp:** Die exakten `--ad-group`-Werte je Schule + fertige `create`-Befehle liefert
> `scripts/discover-ad-facts.sh` (auf dem DC ausführen, join-frei) — beugt vertippten
> Gruppennamen vor (die sonst einen stillen 403 verursachen).

```
lmnsquid create --school default-school --role teachers --ad-group teachers \
  --realm LINUXMUSTER.MEINESCHULE.DE \
  --visible-hostname proxy-teachers.linuxmuster.meineschule.de \
  --image ghcr.io/faircomp/linuxmuster-squid@sha256:<digest> \
  --keytab-secret proxy.keytab --school-subnets 10.1.0.0/16
lmnsquid list
lmnsquid status default-school-teachers
lmnsquid stop|start|restart default-school-teachers
lmnsquid logs default-school-teachers --tail 100
lmnsquid rm default-school-teachers
```
Der Keytab muss vorher als Secret `<keytab-secret>` in `secrets_dir`
(`/etc/linuxmuster-squid/secrets`) liegen — siehe `keytab-and-dns.md`.

## Updates (digest-gepinnt, Health-Auto-Rollback)

```
lmnsquid update default-school-teachers ghcr.io/faircomp/linuxmuster-squid@sha256:<neu>
lmnsquid rollback default-school-teachers        # auf den letzten Known-Good
```
Das Update pullt den neuen Digest, ersetzt den Container, wartet auf `healthy` und
**rollt bei Fehler automatisch zurück** — die Schule bleibt online. Welcher Digest
produktiv gehört, entscheidet ein **gemergter Renovate-PR** (nie Auto-Merge).

## Beobachten

```
systemctl status linuxmuster-squid ; journalctl -u linuxmuster-squid
docker ps --filter name=lmnsquid-                # laufende Proxy-Container
lmnsquid status <name>                            # exists/running/health/image
lmnsquid logs <name> --tail 100 --grep teacher1   # Live: Access + Squid, optional gefiltert
lmnsquid logs <name> --since 1783000000            # ab Unix-Epoch-Sekunde
lmnsquid access-logs <name> --grep blocked.example --since 1782900000  # HISTORIE (Tage/Monate)
```
Mutationen der API laufen ins Audit-Log (`logger "lmnsquid.audit"`).

## Logs, Rotation & Aufbewahrung

- **Zwei Log-Wege:** (1) der Squid-**Access-Log** wird per Tailer auf Container-stdout
  gespiegelt → `docker/lmnsquid logs` (Live-Blick, gedeckelter docker-json-log); (2) die
  **dauerhafte, durchsuchbare Historie** liegt gzip-rotiert im **persistenten Log-Volume**
  `lmnsquid-logs-<name>` (`/var/log/squid`), überlebt Neustarts/Updates.
- **Rotation:** `logrotate` rotiert täglich + gzip; behalten wird `--log-retention-days`
  (Default **30**, konfigurierbar bis 3650) → das *ist* die Aufbewahrungs-/Löschfrist.
- **Historie abfragen:** `GET /v1/instances/{name}/logs/access?since=&until=&grep=` bzw.
  `lmnsquid access-logs …` durchsucht alle rotierten `.gz`-Tagesdateien.
- **Plattenplatz:** grob `Retention-Tage × ~2 MB gepackt × Instanzen` — bei 90 Tagen
  ≈ 180 MB/Instanz. Im Blick behalten.
- **Für zentrale Langzeit-Analyse** stattdessen den Docker-`syslog`-Log-Treiber an euren
  vorhandenen syslog/SIEM hängen — die Control-Plane ist **keine** Log-Datenbank.

### ⚠️ Datenschutz (DSGVO)

Access-Logs zeigen **wer welche Seite besucht/geblockt bekam** = personenbezogene Daten
(Schüler-Surfverhalten). Daher:
- **Retention knapp halten** und dokumentieren (Zweckbindung, Löschfrist = `log_retention_days`).
- **Access-Logging pro Instanz abschaltbar:** `access_log_enabled: false` → Squid protokolliert
  keine Requests (die Gruppen-ACL/Filterung greift unverändert).
- Zugriff auf die Logs (API-Token) eng halten; Abfragen laufen ins Audit-Log.

## Sicherung

- `/etc/linuxmuster-squid/config.yml` (API-Token!), `/etc/linuxmuster-squid/secrets/` (Keytabs),
- `instances_dir` (`/var/lib/linuxmuster-squid/instances/*.yaml` — git-versioniert = Change-Log).

## Sicherheits-Posture (Kurz)

- API nur `127.0.0.1`, Bearer-Token (konstant-zeitiger Vergleich); Docker-Socket-Zugriff
  ist **root-äquivalent** → nicht über localhost hinaus exponieren, Socket-Proxy empfohlen.
- Data-Plane-Container: non-root (`proxy`), **read-only-Rootfs**, `cap_drop: ALL`,
  `no-new-privileges`, Keytab als ro-Secret. Kein HTTPS-MITM (nur SNI-splice/CONNECT).
- systemd-Dienst gehärtet (`ProtectSystem=strict`, `NoNewPrivileges`, …).
