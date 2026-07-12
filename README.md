<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# linuxmuster-squid

Containerized, multi-instance **Squid proxy for [linuxmuster.net](https://linuxmuster.net) 7**
with **Kerberos SSO** against Samba Active Directory and **group-based
access rules** (teachers / students), one isolated instance per
**(school × role)** — managed via a **REST API + CLI**.

> **Status:** **`v1.2.0` — code-complete & E2E-verified** (all 11 phases
> P0–P11, `run.sh all` green: Unit 62 + mypy + ruff + E2E 9/9 + docker integration +
> `.deb` install/upgrade + class load 50/50; security review with all findings fixed —
> see **[`CHANGELOG.md`](CHANGELOG.md)**). Before
> production use, still **human gates**: manual Windows GPO acceptance
> (**[`docs/deployment-gpo.md`](docs/deployment-gpo.md)**), GPG signing of the `.deb`
> with the linuxmuster key, site-specific AD facts (Realm/Base DN/group DN).

## Why

linuxmuster.net 7 still uses Squid, but **built into OPNsense** — with
Kerberos SSO via the **`os-web-proxy-sso`** plugin, which is **deprecated/unmaintained**
(removal planned from OPNsense 26.1). Group policies (teachers/students)
hang on a fragile community plugin, **there is no multischool isolation**,
and the proxy shares resources with routing/NAT on the firewall.

`linuxmuster-squid` extracts the identity/filter layer out of the firewall and
cleanly delivers the two things the OPNsense approach never had: **robust
teacher/student group policy** and **multischool isolation** — while reusing
the same AD/Kerberos infrastructure the school already operates.

## Architecture at a glance

- **Data Plane:** N Squid containers (one per school × role). Explicit forward proxy
  (Kerberos proxy auth is technically impossible in transparent mode),
  authentication via `negotiate_kerberos_auth`, authorization via
  `ext_kerberos_ldap_group_acl` against the instance's AD group. HTTPS is
  **not decrypted** (SNI peek/splice or CONNECT `dstdomain`).
- **Control Plane:** hardened systemd service with **REST API** (FastAPI) and
  **CLI** (Typer, thin client) — creates instances, configures policies, and
  **updates digest-pinned with health-check auto-rollback**. Shipped as a
  signed `.deb`.

Details: [`docs/architecture.md`](docs/architecture.md).

## Usage

**1. Install** on the proxy host (a Linux/Docker VM — *not* the linuxmuster server):
```bash
# fetch the .deb from the latest release (CI builds it per tag) and install
gh release download -R faircomp/linuxmuster-squid -p 'linuxmuster-squid_*.deb'
sudo apt install -y ./linuxmuster-squid_*.deb     # postinst: user + config, starts on 127.0.0.1:8080
sudo ln -sf /opt/linuxmuster-squid/venv/bin/lmnsquid /usr/local/bin/lmnsquid
sudo lmnsquid health                              # {"status":"ok"}
```
The keytab is created **once on the Samba AD DC** and copied to
`/etc/linuxmuster-squid/secrets/` on the proxy host — see [`docs/keytab-and-dns.md`](docs/keytab-and-dns.md).

**2. Create the proxies.** Use the **global role groups** (`role-teacher` / `role-student`)
so a visitor from another school is accepted at the local proxy, and list **one `internet`
group per school** so the linuxmuster *Internetsperre* still works everywhere (a user passes
if in **any** of them):
```bash
# one teacher proxy (:3128) + one student proxy (:3129) for the whole domain
sudo lmnsquid create --school all --role teachers --ad-group role-teacher \
  --realm EXAMPLE.ORG --visible-hostname proxy.example.org \
  --keytab-secret proxy.keytab --http-port 3128 --school-subnets 10.0.0.0/8

sudo lmnsquid create --school all --role students --ad-group role-student \
  --internet-group internet --internet-group school2-internet \
  --realm EXAMPLE.ORG --visible-hostname proxy.example.org \
  --keytab-secret proxy.keytab --http-port 3129 --school-subnets 10.0.0.0/8
```
> `REALM=EXAMPLE.ORG bash scripts/discover-ad-facts.sh` (on the DC) prints your exact group
> names + ready-made `create` commands. `--image` defaults to the maintained, digest-pinned image.

**3. Everyday commands:**
```bash
lmnsquid list                              # all instances
lmnsquid status all-teachers               # health / running / image
lmnsquid logs all-students --tail 100      # live access + squid log
lmnsquid edit all-teachers --internet-group internet --internet-group school2-internet
lmnsquid update all-teachers               # -> maintained default image (health auto-rollback)
lmnsquid update-all                        # every instance -> default image
lmnsquid rollback all-teachers             # to the last known-good
lmnsquid reconcile                         # re-apply stored state (restore / after a crash)
lmnsquid version
```

**4. Point clients at the proxy** per role via **GPO** (silent Kerberos SSO; the visitor case
is handled by the global role groups) — full recipe in [`docs/deployment-gpo.md`](docs/deployment-gpo.md).
The proxy binds all interfaces by default; an unauthenticated request returns **407**. Day-to-day
operations, logs & on-disk paths: [`docs/operations.md`](docs/operations.md).

## Development & Tests

The fast tier (lint/unit) runs locally/CI. The **heavy tier** — the real
Kerberos E2E (Samba AD DC + Squid + client, proving *teacher→200 /
student→403 / blocked→403 / no-ticket→407*) — needs a **Linux host with
Docker**. Aggregator:
`bash scripts/tests/run.sh [lint|unit|quick|e2e|all]`.

## Security (brief)

Keytabs are domain credentials (secret/tmpfs, least-privilege). **No
HTTPS decryption** (privacy-friendly, no client CA rollout). Control-plane
Docker socket access is **root-equivalent** — API only on
localhost/mgmt network, token/TLS, behind a socket proxy. More:
[`docs/threat-model.md`](docs/threat-model.md) · [`docs/keytab-and-dns.md`](docs/keytab-and-dns.md).

## License

**`GPL-3.0-or-later`** — consistent with the GPL ecosystem of linuxmuster.net.
The project is [REUSE 3.3](https://reuse.software)-compliant: every file carries an
SPDX header, license texts live in [`LICENSES/`](LICENSES/), and `reuse lint` is gated
in CI. See [`docs/decisions.md`](docs/decisions.md) (ADR-000). © Kevin Stenzel.
