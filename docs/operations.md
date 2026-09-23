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

> **Tip:** The global role groups (`--ad-group`), the internet groups per school
> (`--internet-group`) and ready-made `create` commands are printed by
> `/usr/share/linuxmuster-squid/scripts/discover-ad-facts.sh` (run on the DC, join-free) —
> prevents mistyped group names (which would otherwise cause a silent 403). First-time setup
> end to end: [`install.md`](install.md).

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
lmnsquid rm default-school-teachers               # + cache/log volumes, blocklist, .prev; --keep-logs keeps the log volume
```
The keytab must already be present as secret `<keytab-secret>` in `secrets_dir`
(`/etc/linuxmuster-squid/secrets`) — see `keytab-and-dns.md`.

- **`--image` is optional:** it defaults to the maintained, digest-pinned data-plane
  image; pass `--image ghcr.io/…@sha256:<digest>` only to override a specific instance.
- **`--school-subnets` is repeatable:** `--school-subnets 10.1.0.0/16 --school-subnets 10.3.0.0/16`
  (a comma- or space-separated single value works too).
- **`--internet-group` (optional, repeatable):** also require the linuxmuster **internet**
  group — honours *Internetsperre* (removing a user from the group blocks their new requests
  within ~10s). List **one per school** (`--internet-group internet --internet-group
  msg-internet`) so it covers **visitors** too and works with global `role-teacher`/`role-student`
  proxies — a user passes if in **any** listed group. Omit to enforce the role group only.
- **`lmnsquid rm <name>`** removes the container, the cache volume, the **log volume**
  (`lmnsquid-logs-<name>` = access-log history, personal data), the blocklist directory and
  the definition (+ its `.prev` rollback note). `--keep-logs` (API: `?keep_logs=true`) keeps
  the log volume, e.g. for a retention obligation; delete it later with
  `docker volume rm lmnsquid-logs-<name>`. The keytab in `secrets/` stays (operator-managed).

## Blocklist (per instance)

Each instance has its own domain list, `/etc/linuxmuster-squid/blocklists/<name>/blocked.domains`
(created empty on `create`), which the container sees read-only at `/etc/squid/lists/blocked.domains`
— the file its `squid.conf` reads for `dstdomain` (HTTP + CONNECT) and `ssl::server_name` (SNI).

```
lmnsquid blocklist default-school-students add example.org      # -> [".example.org"]: the domain and all subdomains
lmnsquid blocklist default-school-students list
lmnsquid blocklist default-school-students remove example.org
lmnsquid blocklist default-school-students reload               # squid re-reads the list: no restart, cache and connections stay
```

- `add`/`remove` write the file (sorted, one `.domain` per line; comments are not
  preserved) and take effect on the next **`reload`** — batch your changes, then reload once.
  `reload` runs `squid -k reconfigure` inside the container (docker exec, like
  `access-logs` — not available behind the socket proxy with `EXEC: 0`); the auth/group
  helpers restart, the cache stays. API:
  `GET/POST /v1/instances/{name}/blocklist`, `DELETE …/blocklist/{domain}`, `POST …/blocklist/reload`.
- **What the user sees:** HTTP → **403** (Squid error page, also for teachers). HTTPS → the
  proxy peeks at the SNI and **terminates the TLS handshake**: the browser shows a
  connection/TLS error, *not* a block page (there is none without decryption, ADR-002).
  A blocked name shows up as `TCP_DENIED/403 … GET http://…` resp. `TCP_DENIED/200 0 CONNECT …:443`
  in the access log.
- **Hand-editing / category lists:** the file may be edited directly (one domain per line,
  leading dot = with subdomains; `#` comments) followed by `lmnsquid blocklist <name> reload`.
  UT-Capitole category lists: `INSTANCE=<name> BLOCK_CATEGORIES="adult malware phishing"
  bash /usr/share/linuxmuster-squid/scripts/blocklist-refresh.sh` from a host cron **as user
  `lmnsquid`** (fail-closed size floor), then `reload`. The refresh **replaces the whole
  file** — entries added with `lmnsquid blocklist add` are lost, so keep manually curated
  instances out of the refresh or re-add them afterwards. The directory must stay owned by
  `lmnsquid` so the API can keep writing (it replaces the file atomically).
- **Upgraded from 7.3.0?** Containers created before 7.3.1 run without the mount until
  recreated once; the postinst runs `lmnsquid reconcile` for that (see Updates).

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

**Upgrade from 7.3.0 (or older) to 7.3.1:** instances created before 7.3.1 have no blocklist
mount, and `update-all` skips them when the default image did not move. The postinst therefore
runs `lmnsquid reconcile` once when the previous version is `< 7.3.1`: it replaces exactly the
containers whose definition differs from what they were created from (see below), a few
seconds per instance. Check with
`docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' lmnsquid-<name>` (must list
`/etc/squid/lists`); if the postinst could not reach the API, run `lmnsquid reconcile` yourself.
Both postinst steps log their output to the journal (`journalctl -t linuxmuster-squid`) and
print a `WARNING:` in the apt output when an instance was rolled back or not brought up — the
apt transaction itself never fails over them.

**How a container is replaced** (create, edit, update, rollback, reconcile): the new container
is created first, the old one is stopped and parked, the new one is started and must become
**healthy**; only then is the old one removed. If the new one exits or stays unhealthy, it is
removed, the old one is restarted, and the operation reports the error (HTTP 500 for a single
instance; `reconcile` lists the name under `failed` and the CLI exits 1 while the other
instances are still reconciled). A container that already matches its definition (label
`lmnsquid.spec`) is left running — so `lmnsquid reconcile` is safe to run at any time and an
`edit` that changes nothing causes no restart. Use `lmnsquid restart <name>` for a plain restart.

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
- **`lmnsquid rm` deletes the log volume** with the instance (the deletion path); pass
  `--keep-logs` only when a retention obligation requires it.

## Backup

- `/etc/linuxmuster-squid/config.yml` (API token!), `/etc/linuxmuster-squid/secrets/` (keytabs),
  `/etc/linuxmuster-squid/blocklists/` (per-instance blocklists),
- `instances_dir` (`/var/lib/linuxmuster-squid/instances/*.yaml` — git-versioned = change log;
  the postinst creates and configures the repo as its owner `lmnsquid`, with git's background
  maintenance off; every create/edit/update/rm is one commit:
  `git -C /var/lib/linuxmuster-squid/instances log --oneline` works as root, the postinst
  registers the directory as `safe.directory`; run *writing* git commands as the owner
  (`sudo -u lmnsquid git -C /var/lib/linuxmuster-squid/instances …`): what root writes there
  belongs to root, and the service's commits can fail on it until the next package configure
  hands it back),
- Log **volumes** (`lmnsquid-logs-<name>`) only if the access history is subject to retention
  requirements — the cache volume (`lmnsquid-cache-<name>`) is **disposable**.

## Restore / disaster recovery

Fresh host → running instances:
```
apt install ./linuxmuster-squid_<version>_all.deb          # service comes up
# keep the API token: restore config.yml OR accept the new token
cp -a <backup>/secrets/*        /etc/linuxmuster-squid/secrets/      # keytabs
cp -a <backup>/blocklists/*     /etc/linuxmuster-squid/blocklists/   # per-instance blocklists (optional; empty ones are recreated)
cp -a <backup>/instances/*.yaml /var/lib/linuxmuster-squid/instances/
chown -R lmnsquid:lmnsquid /etc/linuxmuster-squid /var/lib/linuxmuster-squid/instances
lmnsquid reconcile      # reads the desired state + pulls the pinned digests -> containers run
```
- **`lmnsquid reconcile`** (`POST /v1/reconcile`) re-applies **all** stored instances
  — also to fix drift after an incident. Containers that already match are left alone, a
  missing one is created, a differing one replaced (old one kept until the new one is
  healthy); one failing instance does not stop the rest (`failed` list, CLI exit 1).
- **Reboot** doesn't need this: `restart_policy: unless-stopped` brings running containers back.
- **Downgrade the tool:** install an older `.deb` → the postinst restarts the service
  (loads the old code). **Cache volume broken** (container stays unhealthy after a power outage):
  `docker rm -f <container>` + `docker volume rm lmnsquid-cache-<name>` → `lmnsquid reconcile`.

## Security posture (brief)

- API on `127.0.0.1` only, Bearer token (constant-time comparison); Docker socket access
  is **root-equivalent** → do not expose beyond localhost, socket proxy recommended.
- Proxy ports bind **all interfaces** (`container_bind_ip=0.0.0.0`) by default so LAN clients
  can reach them — access is gated by **Kerberos + the group ACL** (an unauthenticated request
  gets 407). Narrow `container_bind_ip` to a specific IP if the host has an untrusted interface.
- Data-plane container: non-root (`proxy`), **read-only rootfs**, `cap_drop: ALL`,
  `no-new-privileges`, keytab as ro secret. No HTTPS MITM (only SNI splice/CONNECT).
- systemd service hardened (`ProtectSystem=strict`, `NoNewPrivileges`, …).
