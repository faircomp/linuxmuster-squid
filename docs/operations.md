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
docker logs lmnsquid-default-school-teachers      # Squid access/cache log
lmnsquid status <name>                            # exists/running/health/image
```
Mutationen der API laufen ins Audit-Log (`logger "lmnsquid.audit"`).

## Sicherung

- `/etc/linuxmuster-squid/config.yml` (API-Token!), `/etc/linuxmuster-squid/secrets/` (Keytabs),
- `instances_dir` (`/var/lib/linuxmuster-squid/instances/*.yaml` — git-versioniert = Change-Log).

## Sicherheits-Posture (Kurz)

- API nur `127.0.0.1`, Bearer-Token (konstant-zeitiger Vergleich); Docker-Socket-Zugriff
  ist **root-äquivalent** → nicht über localhost hinaus exponieren, Socket-Proxy empfohlen.
- Data-Plane-Container: non-root (`proxy`), **read-only-Rootfs**, `cap_drop: ALL`,
  `no-new-privileges`, Keytab als ro-Secret. Kein HTTPS-MITM (nur SNI-splice/CONNECT).
- systemd-Dienst gehärtet (`ProtectSystem=strict`, `NoNewPrivileges`, …).
