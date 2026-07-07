<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Operations

Quick reference for day-to-day operations. Architecture → [`architecture.md`](architecture.md),
client rollout → [`deployment-gpo.md`](deployment-gpo.md), keytabs/DNS →
[`keytab-and-dns.md`](keytab-and-dns.md).

## Installation (control-plane tooling)

```
apt install ./linuxmuster-squid_<version>_all.deb     # or from the lmn73 apt repo
systemctl status linuxmuster-squid                    # should be "active"
```
The postinst creates the system user `lmnsquid` (in group `docker`), generates a
random API token in `/etc/linuxmuster-squid/config.yml` (0600) and starts the service
(bound to `127.0.0.1:8080`).

## Managing instances (CLI = thin client of the REST API)

> **Tip:** The exact `--ad-group` values per school + ready-made `create` commands are
> provided by `scripts/discover-ad-facts.sh` (run on the DC, join-free) — prevents mistyped
> group names (which would otherwise cause a silent 403).

```
lmnsquid create --school default-school --role teachers --ad-group teachers \
  --realm LINUXMUSTER.MEINESCHULE.DE \
  --visible-hostname proxy-teachers.linuxmuster.meineschule.de \
  --keytab-secret proxy.keytab \
  --school-subnets 10.1.0.0/16 --school-subnets 10.3.0.0/16
lmnsquid list
lmnsquid status default-school-teachers
lmnsquid stop|start|restart default-school-teachers
lmnsquid logs default-school-teachers --tail 100
lmnsquid rm default-school-teachers
```
The keytab must already be present as secret `<keytab-secret>` in `secrets_dir`
(`/etc/linuxmuster-squid/secrets`) — see `keytab-and-dns.md`.

- **`--image` is optional:** it defaults to the maintained, digest-pinned data-plane
  image; pass `--image ghcr.io/…@sha256:<digest>` only to override a specific instance.
- **`--school-subnets` is repeatable:** `--school-subnets 10.1.0.0/16 --school-subnets 10.3.0.0/16`
  (a comma- or space-separated single value works too).

## Updates (digest-pinned, health auto-rollback)

```
lmnsquid update default-school-teachers                                        # -> maintained default digest
lmnsquid update default-school-teachers ghcr.io/faircomp/linuxmuster-squid@sha256:<new>   # explicit pin
lmnsquid update-all                              # every instance -> default image (per-instance rollback)
lmnsquid rollback default-school-teachers        # to the last known-good
```
The update pulls the new digest, replaces the container, waits for `healthy` and
**automatically rolls back on failure** — the school stays online. Which digest
belongs in production is decided by a **merged Renovate PR** (never auto-merge).

On a **`.deb` upgrade** the postinst runs `update-all` automatically (best-effort): all
instances are lifted onto that package's pinned default image, each with its own health-check
auto-rollback; instances already on the default are skipped, and the apt transaction never
fails over this. Run `lmnsquid update-all` yourself any time to do the same on demand.

## Observing

```
systemctl status linuxmuster-squid ; journalctl -u linuxmuster-squid
docker ps --filter name=lmnsquid-                # running proxy containers
lmnsquid status <name>                            # exists/running/health/image
lmnsquid logs <name> --tail 100 --grep teacher1   # live: access + Squid, optionally filtered
lmnsquid logs <name> --since 1783000000            # from Unix epoch second
lmnsquid access-logs <name> --grep blocked.example --since 1782900000  # HISTORY (days/months)
```
API mutations go to the audit log (`logger "lmnsquid.audit"`). If the Docker daemon
is gone, the API responds with **503** (not a raw 500).

### Alerting & auth health (without a monitoring stack)

- **Report instance down/unhealthy:** hook existing signals into your school infra, e.g.
  `docker events --filter event=health_status --filter event=die` into a script that sends a
  mail/Matrix message on `unhealthy`/`die` (no Prometheus needed).
- **Detect keytab expiry early** (otherwise the whole school goes offline when the service
  account rotates its password): `klist -kt <keytab>` shows KVNO/enctypes; a cron alerts on a
  spike of `Negotiate … BH` / 407-after-ticket in the access log
  (`lmnsquid access-logs <name> --grep BH`). After rotation: re-export the keytab, `restart`
  the instance. See [`keytab-and-dns.md`](keytab-and-dns.md) (KVNO/SPN pitfalls).

## Logs, rotation & retention

**Where they are on disk** (`<name>` = instance name, e.g. `default-school-teachers`; the
container is `lmnsquid-<name>`):

- **Control-plane service:** systemd journal only — `journalctl -u linuxmuster-squid` (no log
  file on disk). API mutations additionally go to the audit log (`logger` tag `lmnsquid.audit`
  → syslog/journal).
- **Squid access log:** container `/var/log/squid/access.log`; on the host in the per-instance
  volume `lmnsquid-logs-<name>` → `/var/lib/docker/volumes/lmnsquid-logs-<name>/_data/`
  (default local driver), with rotated `access.log.<n>.gz` alongside.
- **Squid cache log:** container `/var/log/squid/cache.log`, same volume (rotated weekly, keep 4).
- **Cache spool** (not a log, same scheme): volume `lmnsquid-cache-<name>` → `/var/spool/squid`
  — disposable.

The control-plane install tree itself (`/opt`, `/etc`, `/var/lib/linuxmuster-squid`) holds **no**
logs; all request/cache logs live in the Docker volumes above.

- **Two log paths:** (1) the Squid **access log** is mirrored to container stdout by a tailer
  → `docker/lmnsquid logs` (live view, capped docker-json log); (2) the **durable, searchable
  history** lives gzip-rotated in the **persistent log volume** `lmnsquid-logs-<name>`
  (`/var/log/squid`), surviving restarts/updates.
- **Rotation:** `logrotate` rotates daily + gzip; retained is `--log-retention-days`
  (default **30**, configurable up to 3650) → that *is* the retention/deletion period.
- **Query history:** `GET /v1/instances/{name}/logs/access?since=&until=&grep=` or
  `lmnsquid access-logs …` searches all rotated `.gz` daily files.
- **Disk space:** roughly `retention-days × ~2 MB packed × instances` — at 90 days
  ≈ 180 MB/instance. Keep an eye on it.
- **For centralized long-term analysis** instead hook the Docker `syslog` log driver into your
  existing syslog/SIEM — the control plane is **not** a log database.

### ⚠️ Data protection (GDPR)

Access logs show **who visited/was blocked from which site** = personal data
(student browsing behavior). Therefore:
- **Keep retention tight** and document it (purpose limitation, deletion period = `log_retention_days`).
- **Access logging can be disabled per instance:** `access_log_enabled: false` → Squid logs
  no requests (the group ACL/filtering still applies unchanged).
- Keep access to the logs (API token) tight; queries go to the audit log.

## Backup

- `/etc/linuxmuster-squid/config.yml` (API token!), `/etc/linuxmuster-squid/secrets/` (keytabs),
- `instances_dir` (`/var/lib/linuxmuster-squid/instances/*.yaml` — git-versioned = change log;
  the postinst creates the repo),
- Log **volumes** (`lmnsquid-logs-<name>`) only if the access history is subject to retention
  requirements — the cache volume (`lmnsquid-cache-<name>`) is **disposable**.

## Restore / disaster recovery

Fresh host → running instances:
```
apt install ./linuxmuster-squid_<version>_all.deb          # service comes up
# keep the API token: restore config.yml OR accept the new token
cp -a <backup>/secrets/*        /etc/linuxmuster-squid/secrets/      # keytabs
cp -a <backup>/instances/*.yaml /var/lib/linuxmuster-squid/instances/
chown -R lmnsquid:lmnsquid /etc/linuxmuster-squid/secrets /var/lib/linuxmuster-squid/instances
lmnsquid reconcile      # reads the desired state + pulls the pinned digests -> containers run
```
- **`lmnsquid reconcile`** (`POST /v1/reconcile`) re-applies **all** stored instances
  — also to fix drift after an incident.
- **Reboot** doesn't need this: `restart_policy: unless-stopped` brings running containers back.
- **Downgrade the tool:** install an older `.deb` → the postinst restarts the service
  (loads the old code). **Cache volume broken** (container stays unhealthy after a power outage):
  `docker rm -f <container>` + `docker volume rm lmnsquid-cache-<name>` → `lmnsquid reconcile`.

## Security posture (brief)

- API on `127.0.0.1` only, Bearer token (constant-time comparison); Docker socket access
  is **root-equivalent** → do not expose beyond localhost, socket proxy recommended.
- Data-plane container: non-root (`proxy`), **read-only rootfs**, `cap_drop: ALL`,
  `no-new-privileges`, keytab as ro secret. No HTTPS MITM (only SNI splice/CONNECT).
- systemd service hardened (`ProtectSystem=strict`, `NoNewPrivileges`, …).
