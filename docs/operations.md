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
apt install ./linuxmuster-squid_<version>_amd64.deb   # or from the lmn73 apt repo
systemctl status linuxmuster-squid                    # should be "active"
```
The postinst creates the system user `lmnsquid` (in group `docker`), generates a
random API token in `/etc/linuxmuster-squid/config.yml` (0600) and enables and starts the
service (bound to `127.0.0.1:8080`). After that the package keeps the admin's decision:
[Keeping the service off](#keeping-the-service-off).

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
lmnsquid rm default-school-teachers               # + cache/log volumes, both lists, .prev; --keep-logs keeps the log volume
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
  (`lmnsquid-logs-<name>` = access-log history, personal data), the list directory (blocklist
  and noauth list) and
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
  A name below a listed domain is already covered: adding it changes nothing, and adding a
  parent removes the names below it (squid 6 refuses to load a list in which a covered name,
  e.g. `.a.example.org` or `example.org`, comes before `.example.org`: `FATAL: Bungled`).
  `reload` runs `lists-sync.sh` and `squid -k reconfigure` inside the container (docker exec, like
  `access-logs` — not available behind the socket proxy with `EXEC: 0`); the auth/group
  helpers restart, the cache stays. API:
  `GET/POST /v1/instances/{name}/blocklist`, `DELETE …/blocklist/{domain}`, `POST …/blocklist/reload`.
- **What the user sees:** HTTP → **403** (Squid error page, also for teachers). HTTPS → a
  **certificate warning**, no block page: squid refuses the CONNECT to the blocked host by
  answering it itself, with `200` and then TLS with the instance's untrusted throwaway
  certificate and its 403 page inside; the target is never contacted. Someone who clicks
  through the warning sees the 403 page, and the proxy sees the path and headers of that
  request (it never sees traffic of an allowed site, that is spliced). A blocked name only in
  the SNI (behind an allowed CONNECT host) is cut during the TLS handshake: connection error.
  ADR-002 (clarification) has the details. In the access log a blocked name shows up as
  `TCP_DENIED/403 … GET http://…`, resp. `NONE_NONE/200 0 CONNECT <host>:443` followed by
  `NONE_NONE/403 … GET https://<host>/…` when the client accepted the certificate.
- **Hand-editing / category lists:** the file may be edited directly (one domain per line,
  leading dot = with subdomains; `#` comments; Windows line endings are fine) followed by
  `lmnsquid blocklist <name> reload`.
  Squid does not read the mounted file itself: at every start and reload the image's
  `lists-sync.sh` builds the list it reads (`/run/lmnsquid/lists/`) and leaves out every entry
  a listed parent domain already covers, naming them in `lmnsquid logs <name>`
  (`… entries ignored, already covered by a listed parent domain: …`) and, for a reload, also
  in its answer (`"notices": [...]`); so a hand-edited list
  cannot stop the proxy. `blocklist-refresh.sh` drops those entries itself. (The image pinned
  by 7.3.7 and older reads the mounted file directly: with it such a list makes `reload` fail
  and the next start of the container fail.)
  UT-Capitole category lists: `INSTANCE=<name> BLOCK_CATEGORIES="adult malware phishing"
  bash /usr/share/linuxmuster-squid/scripts/blocklist-refresh.sh` from a host cron **as user
  `lmnsquid`** (fail-closed size floor), then `reload`. The refresh **replaces the whole
  file** — entries added with `lmnsquid blocklist add` are lost, so keep manually curated
  instances out of the refresh or re-add them afterwards. The directory must stay owned by
  `lmnsquid` so the API can keep writing (it replaces the file atomically).
- **Upgraded from 7.3.0?** Containers created before 7.3.1 run without the mount until
  recreated once; the postinst runs `lmnsquid reconcile` for that (see Updates).

## Domains without proxy authentication (per instance)

Each instance can let a list of domains through **without proxy authentication** (ADR-016),
`/etc/linuxmuster-squid/blocklists/<name>/noauth.domains` (created empty with the instance),
seen by the container at `/etc/squid/lists/noauth.domains` — the same mounted directory as the
blocklist. Empty = every request needs a ticket, as before.

```
lmnsquid noauth all-students add sharepoint.com      # -> [".sharepoint.com"]: the domain and all subdomains
lmnsquid noauth all-students list
lmnsquid noauth all-students remove sharepoint.com
lmnsquid noauth all-students reload                  # squid re-reads both lists: no restart
```

> **⚠️ Warning — read before adding anything:**
> - **Exam mode:** exam accounts (and every other device in the school subnets) reach a listed
>   domain without a ticket during an exam, e.g. OneDrive, Teams and Outlook with the
>   Microsoft 365 list below, although the proxy refuses them everything else.
> - **Internetsperre:** does not apply to listed domains (without identity there is no group
>   check); a user removed from the `internet` group still reaches them.
> - **No user in the log:** these requests appear as `-` in the access log.
> - **Only from `--school-subnets`:** from anywhere else a ticket is still required. With the
>   default `0.0.0.0/0` that is everyone who can reach the proxy port, so set the real client
>   subnets (`lmnsquid edit <name> --school-subnets …`) before using the list.

- **Rules:** the blocklist wins (a domain on both lists gets **403**; HTTPS is cut). The
  existing rules stay in front (Safe_ports, CONNECT only to 443, no IP literals on CONNECT); an
  IP-literal URL never matches the list (`dstdomain -n`, no reverse DNS; addresses cannot be
  put on it, see below). HTTPS through the
  list passes only when the TLS **SNI** is on the list too; a different SNI or a ClientHello
  without SNI is **terminated** (no domain fronting into other names; no decryption, ADR-002).
  With a ticket nothing changes (200 / 403 / 407 as before).
- `add`/`remove` write the file (same format and rules as the blocklist, one `.domain` per
  line, `#` comments allowed when hand-edited) and take effect on the next **`reload`**.
  Stricter names than the blocklist: only a domain below a top-level domain, so `add` refuses
  IP addresses in any form (IPv6, and every IPv4 notation `inet_aton` reads: `10.0.0.1`,
  `127.1`, `0x7f000001`, `0x7f.0x1`, `1.2.3.0x4`; refused is any name whose labels are all
  decimal, octal or `0x` numbers) and single labels such as
  `com` (they would open an address or a whole TLD); hand-written lines of that kind are
  ignored by the container and named in `lmnsquid logs <name>` and in the answer of
  `lmnsquid noauth <name> reload` (`"notices"`). The blocklist accepts both on
  purpose: blocking a TLD (`zip`) is a legitimate choice and a wrong entry there only blocks
  more. API:
  `GET/POST /v1/instances/{name}/noauth`, `DELETE …/noauth/{domain}`, `POST …/noauth/reload`.
- **`reload` answers 409** when the instance's data-plane image does not support the list
  (an image from before the list). That is a release matter, not an admin step: a
  linuxmuster-squid release whose pinned image supports the list moves the instances onto it
  when the package is upgraded (`update-all` in the postinst); `lmnsquid update <name>` only
  helps once such a release is installed (then it moves an instance that stayed on its old
  image, e.g. after a rollback). The 409 text says the same. Without that check a reload would report success and
  change nothing.
  `blocklist reload` is not affected. A `noauth.domains` created after the container started
  (an older control plane) is picked up by the next reload.
- **What `lmnsquid rm` removes:** the directory with both lists.

### Recommended list: Microsoft 365

Microsoft asks to exempt the **required** Microsoft 365 endpoints from proxy authentication and
inspection and does not support allowing only some of them ("Routing connections through
network infrastructure applying its own authentication such as proxy authentication" is listed
among the configurations "known to cause connectivity issues"; Microsoft 365 network
connectivity principles, learn.microsoft.com, updated 2026-08-31). Source of the entries:
the Microsoft 365 endpoints web service, `https://endpoints.office.com/endpoints/worldwide`
(service areas Common, Exchange, SharePoint, Skype/Teams; version `2026103000`, fetched
2026-10-30): every **required** item of category **Optimize** or **Allow** with TCP ports
80/443 (ids 1, 9, 12, 31, 46, 56, 64). `*.x` and `x` are both one entry `x` here (the list
always covers the domain and its subdomains, which is slightly wider than `*.x`). Names under
an entry already listed are left out (`ccs.` and `device.login.microsoftonline.com` under
`login.microsoftonline.com`, `api.passwordreset.microsoftonline.com` under
`passwordreset.microsoftonline.com`): they are covered anyway, `add` would not store them, and
squid 6 refuses a list in which such a name comes before its parent.

```
for d in outlook.cloud.microsoft outlook.office.com outlook.office365.com protection.outlook.com \
         lync.com teams.cloud.microsoft teams.microsoft.com sharepoint.com \
         officeapps.live.com online.office.com office.live.com \
         auth.microsoft.com msftidentity.com account.activedirectory.windowsazure.com \
         accounts.accesscontrol.windows.net adminwebservice.microsoftonline.com \
         autologon.microsoftazuread-sso.com clientconfig.microsoftonline-p.net \
         companymanager.microsoftonline.com graph.microsoft.com \
         graph.windows.net login-us.microsoftonline.com login.microsoft.com \
         login.microsoftonline-p.com login.microsoftonline.com login.windows.net \
         logincert.microsoftonline.com loginex.microsoftonline.com nexus.microsoftonline-p.com \
         passwordreset.microsoftonline.com protection.office.com security.microsoft.com \
         compliance.microsoft.com defender.microsoft.com purview.microsoft.com; do
  lmnsquid noauth all-students add "$d" >/dev/null
done
lmnsquid noauth all-students list && lmnsquid noauth all-students reload
```

- **Not on the list, on purpose:** items for mail protocols and SMTP (ids 2 and 10: TCP 25,
  143, 587, 993, 995 — not HTTP proxy traffic) and Teams media (id 11: UDP 3478–3481, no URLs;
  a forward proxy cannot carry UDP — allow it at the firewall if Teams calls are needed).
  Endpoints of category **Default** keep going through the proxy with authentication.
- **The list changes** (Microsoft recommends updating it automatically). Compare from time to
  time with `curl -s 'https://endpoints.office.com/version/worldwide?clientrequestid=<uuid>'`
  and the endpoints call above; for a client that still fails, look for `TCP_DENIED/407` lines
  of Microsoft names in `lmnsquid logs <name>` before adding anything: every entry widens what
  is reachable without identity.

## Updates (digest-pinned, health auto-rollback)

```
lmnsquid update default-school-teachers                                        # -> maintained default digest
lmnsquid update default-school-teachers ghcr.io/faircomp/linuxmuster-squid@sha256:<new>   # explicit pin
lmnsquid update-all                              # every instance -> default image (per-instance rollback)
lmnsquid rollback default-school-teachers        # to the last known-good
```
The update pulls the new digest, replaces the container, waits for `healthy` and
**automatically rolls back on failure** — the school stays online. Which digest
belongs in production is decided by a **merged PR** (never auto-merge; raised by hand while
Renovate is disabled).

On a **`.deb` upgrade** the postinst runs `update-all` automatically (best-effort) when the
service runs after the upgrade: all instances are lifted onto that package's pinned default
image, each with its own health-check auto-rollback; instances already on the default are
skipped, and the apt transaction never fails over this. A service the admin switched off is not
started for it ([Keeping the service off](#keeping-the-service-off)). Run `lmnsquid update-all`
yourself any time to do the same on demand.

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

## Keeping the service off

From 7.3.7 on the package handles its service by Debian's rules (`deb-systemd-helper` and
`deb-systemd-invoke`, as packages built with dh_installsystemd do): a new installation enables
and starts `linuxmuster-squid`; after that, upgrades keep what the admin decided.

- **Switch it off and keep it off:** `systemctl disable --now linuxmuster-squid`. Upgrades,
  reinstalls and `dpkg-reconfigure` leave it disabled and stopped, do not update the instances
  and print one line in the apt output: `linuxmuster-squid: the service is disabled and not
  running, instances not updated; run 'lmnsquid update-all' after starting it`.
  `systemctl stop` alone is not enough: the next upgrade starts an enabled service again.
- **The proxies are separate:** the Squid containers are Docker containers
  (`unless-stopped`) and keep running without the control plane. If they must be off too, stop
  them first with `lmnsquid stop <name>` (it needs the running service).
- **Switch it on again:** `systemctl enable --now linuxmuster-squid`, then `lmnsquid update-all`
  for the instance updates the upgrades skipped.
- **Disabled but still running** (`systemctl disable` without `--now`): an upgrade restarts it
  with the new code and updates the instances; it stays disabled.
- **Masked** (`systemctl mask`): the package leaves it alone.
- **Remove and reinstall:** `apt remove` only stops the service and keeps the decision; a
  reinstall brings it back as it was. `apt purge` forgets it: the next installation is a new one,
  enabled and started. A reinstall after removing 7.3.6 or older is a new installation as well
  (those versions disabled the service on remove).
- **The first upgrade to 7.3.7** takes over the state the service is in at that moment, once:
  7.3.6 and older kept no record of it. Enabled stays enabled, disabled or masked stays so.
  One exception: if this first upgrade runs without a running systemd (an image build, a
  chroot), a service without an enable link is treated like a new installation and enabled,
  because 7.3.6 and older never enabled it offline. Upgrades with systemd running, and every
  later upgrade, keep a service the admin disabled off.
- **Downgrade to 7.3.6 or older:** that version enables and starts the service again.
- **Without a running systemd** (an image build, a chroot) a new installation only enables the
  service; it starts with the next boot.

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
  `/etc/linuxmuster-squid/blocklists/` (per-instance blocklists and noauth lists),
- `instances_dir` (`/var/lib/linuxmuster-squid/instances/*.yaml` — git-versioned = change log;
  the postinst creates and configures the repo as its owner `lmnsquid`, with git's background
  maintenance off; every create/edit/update/rm is one commit:
  `git -C /var/lib/linuxmuster-squid/instances log --oneline` works as root, the postinst
  registers the directory as `safe.directory`; run *writing* git commands as the owner
  (`sudo -u lmnsquid git -C /var/lib/linuxmuster-squid/instances …`): what root writes there
  belongs to root, and the service's commits can fail on it until the next package configure
  hands it back). A git step of the package configure that fails (a damaged repository, a full
  disk) does not fail the install or upgrade: apt shows `WARNING: linuxmuster-squid: change log
  step '<step>' failed (exit <n>) in /var/lib/linuxmuster-squid/instances; …`, the service is
  handled as usual, and only the change log misses that configure's commit; repair the
  repository as `lmnsquid` and run `dpkg-reconfigure linuxmuster-squid`,
- Log **volumes** (`lmnsquid-logs-<name>`) only if the access history is subject to retention
  requirements — the cache volume (`lmnsquid-cache-<name>`) is **disposable**.

## Restore / disaster recovery

Fresh host → running instances:
```
apt install ./linuxmuster-squid_<version>_amd64.deb        # service comes up
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
  (loads the old code); 7.3.6 and older also enable it again. **Cache volume broken**
  (container stays unhealthy after a power outage):
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
