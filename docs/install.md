<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Installation

The complete procedure, as tested against a real linuxmuster.net 7.3 domain (Samba AD DC
`server.<domain>`, proxy host = a separate Ubuntu 24.04 VM with Docker). Every command
was run exactly like this on 2026-09-22 with 7.3.0 → 7.3.1. Background:
[`architecture.md`](architecture.md); day-to-day: [`operations.md`](operations.md);
Kerberos details: [`keytab-and-dns.md`](keytab-and-dns.md); clients:
[`deployment-gpo.md`](deployment-gpo.md).

Placeholders: `<domain>` = the AD DNS domain (`linuxmuster.lan`), `<REALM>` = the same in
UPPERCASE, `<proxy-fqdn>` = the proxy host's FQDN (`proxy.<domain>`), `<subnet>` = the
client network(s). All commands as root.

## 1. Prerequisites (proxy host)

- Ubuntu 24.04 VM in the school network — **not** the linuxmuster server. 2 cores / 4 GB are
  plenty for a school; disk for the cache volumes (1 GB per instance by default) and the
  access-log history (`log_retention_days`, see operations.md).
- `apt-get install -y docker.io krb5-user curl` (`krb5-user` only for the checks below).
- **DNS:** the proxy FQDN needs an A record (and PTR). The linuxmuster DHCP does *not*
  register dynamic leases in the Samba DNS: add the proxy host as a static device in
  `devices.csv` (import creates A/PTR), or on the DC
  `samba-tool dns add <dc-ip> <domain> proxy A <proxy-ip> -U <domain-admin>`.
- **Time:** NTP in sync with the DC (`timedatectl`; Kerberos tolerates < 5 min).
- **`/etc/hosts` on the proxy host:** the proxy FQDN must resolve to the host's LAN IP *on the
  host itself*. cloud-init writes `127.0.1.1 <proxy-fqdn>`; with that, requests from the host
  reach the container via Docker's userland proxy as `172.17.0.1`, outside
  `--school-subnets`, and get 403. Put `<proxy-ip> <proxy-fqdn>` there.
- The proxy host does **not** join the domain (ADR-009); it only needs the keytab from step 3.

## 2. Install the package

```bash
gh release download -R faircomp/linuxmuster-squid -p 'linuxmuster-squid_*.deb'   # or scp it
apt-get install -y ./linuxmuster-squid_7.3.1_all.deb
lmnsquid health          # {"status": "ok"}
lmnsquid version         # {"version": "7.3.1"}  (= dpkg-query -W linuxmuster-squid)
```

The postinst creates the system user `lmnsquid` (in group `docker`), the config
`/etc/linuxmuster-squid/config.yml` with a random API token (0600), `secrets/` (0700) and
`blocklists/`, the git repository `/var/lib/linuxmuster-squid/instances` (the change log of
the instance definitions), and starts the service on `127.0.0.1:8080`. The admin scripts used
below are installed under `/usr/share/linuxmuster-squid/scripts/`.

## 3. Service account and keytab (on the DC)

The proxy authenticates clients with the `HTTP/<proxy-fqdn>` service principal, and its group
helper binds to LDAP as the same account (GSSAPI, no bind password), so the keytab must belong
to a **kinit-capable service account**. One account and one keytab serve all instances on one
host (ADR-008).

Copy `provision-keytab.sh` to the DC (`scp /usr/share/linuxmuster-squid/scripts/provision-keytab.sh root@server:/root/`), then on the DC:

```bash
samba-tool user create svc-squid "$(openssl rand -base64 24)" \
    --description="linuxmuster-squid proxy service account"
samba-tool user setexpiry svc-squid --noexpiry      # a password expiry would kill SSO later (KDC_ERR_KEY_EXP)
bash /root/provision-keytab.sh <proxy-fqdn> svc-squid /root/proxy.keytab
#   == check/append SPN HTTP/<proxy-fqdn> to svc-squid ==
#   == export keytab for svc-squid -> /root/proxy.keytab ==
klist -kt /root/proxy.keytab                          # KVNO n, svc-squid@<REALM> (aes256/aes128/rc4)
```

Move the keytab to the proxy host **without** a stopover on a workstation and remove it from
the DC (it is a domain credential):

```bash
# on the proxy host
ssh root@server 'cat /root/proxy.keytab' \
  | install -m 0600 -o lmnsquid -g lmnsquid /dev/stdin /etc/linuxmuster-squid/secrets/proxy.keytab
ssh root@server 'shred -u /root/proxy.keytab'
# check: the account principal can obtain a ticket with the keytab
kinit -kt /etc/linuxmuster-squid/secrets/proxy.keytab svc-squid && klist && kdestroy
```

`kinit -kt` needs a `/etc/krb5.conf` with `default_realm = <REALM>` on the proxy host (the
containers bring their own). Password reset of the account = new KVNO = re-export the keytab
and `lmnsquid restart <name>` ([`keytab-and-dns.md`](keytab-and-dns.md)).

## 4. Which groups? (on the DC)

```bash
REALM=<REALM> bash /usr/share/linuxmuster-squid/scripts/discover-ad-facts.sh
```

prints the **global role groups** `role-teacher` / `role-student` / `role-staff` (each spans
every school of the domain) for `--ad-group`, the **internet groups** (`internet` for the
default school, `<school>-internet` for the others) for `--internet-group`, and two ready-made
`create` commands. Use the global role groups: a visitor from another school is then accepted at
the local proxy while teacher/student separation still holds. Do **not** use the per-school
`teachers`/`students` groups unless schools must filter differently, and never a class group
(`5a-students` looks like a role group but is not).

## 5. Create one instance per role

```bash
lmnsquid create --school all --role teachers --ad-group role-teacher \
  --realm <REALM> --visible-hostname <proxy-fqdn> \
  --keytab-secret proxy.keytab --http-port 3128 --school-subnets <subnet>

lmnsquid create --school all --role students --ad-group role-student \
  --internet-group internet --internet-group <school>-internet \
  --realm <REALM> --visible-hostname <proxy-fqdn> \
  --keytab-secret proxy.keytab --http-port 3129 --school-subnets <subnet>

lmnsquid list                       # both instances
lmnsquid status all-teachers        # "health": "healthy" after ~10 s ("starting" right after create)
```

Instance name = `<school>-<role>` (`all-teachers`); the container is `lmnsquid-<name>`, the
definition `/var/lib/linuxmuster-squid/instances/<name>.yaml`. `--school-subnets` may be
generous (`10.0.0.0/8`): the group ACL is the real gate, the subnet only defense in depth.
The image defaults to the maintained, digest-pinned data-plane image (pulled from ghcr.io on
first use — the host needs registry access, or pre-load the image).

## 6. Check the policy

From a client in `<subnet>` (or the proxy host with the `/etc/hosts` note from step 1),
`kinit` as a teacher and a student; `Muster!`-style test users are fine:

```bash
P=http://<proxy-fqdn>; U=http://example.com/
req(){ curl -s -o /dev/null -w '%{http_code}\n' --proxy "$1" --proxy-negotiate -U : "$2"; }
kinit teacher1;  req $P:3128 $U        # 200  teacher on the teacher proxy
                 req $P:3129 $U        # 403  authenticated, not in role-student
kinit student1;  req $P:3129 $U        # 200  student on the student proxy (in internet)
                 req $P:3128 $U        # 403  authenticated, not in role-teacher
kdestroy;        req $P:3128 $U        # 407  no ticket -> Negotiate challenge
kinit teacher1;  req http://<proxy-ip>:3128 $U   # 407  proxy by IP = no SPN match, no SSO
```

403 vs 407 is the proof: authenticated-but-unauthorized vs not authenticated.
`lmnsquid logs all-teachers --tail 20` shows the lines (`TCP_MISS/200 … teacher1@<REALM>`,
`TCP_DENIED/403 …`, `TCP_DENIED/407 … -`).

## 7. Blocklist (optional)

Each instance has its own list; `add` blocks the domain **and all subdomains**:

```bash
lmnsquid blocklist all-students add example.org     # -> [".example.org"]
lmnsquid blocklist all-students list
lmnsquid blocklist all-students reload              # squid re-reads the list (no restart)
lmnsquid blocklist all-students remove example.org && lmnsquid blocklist all-students reload
```

HTTP to a blocked domain → **403**. HTTPS to a blocked domain is **cut at the TLS handshake**
(the proxy peeks at the SNI and terminates, it never decrypts): the browser shows a
connection/TLS error, not a block page. Details, the file path and UT-Capitole category
lists: [`operations.md`](operations.md#blocklist-per-instance).

## 8. Clients

Assign the proxy per role by GPO (silent Kerberos SSO) and force the proxy at the firewall:
[`deployment-gpo.md`](deployment-gpo.md). Clients must use the **FQDN**, never the IP.

## 9. Updates

```bash
apt-get install -y ./linuxmuster-squid_<new>_all.deb   # restarts the service, then update-all
lmnsquid update-all                                    # on demand: every instance -> pinned default image
```

Every instance update is health-gated with automatic rollback. **Upgrading from 7.3.0:**
containers created with 7.3.0 run without the blocklist mount until they are recreated
once; the postinst does that (`lmnsquid reconcile`, same image and definition, a few
seconds per instance). Verify with `docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' lmnsquid-<name>`
(shows `/etc/squid/lists`), or run `lmnsquid reconcile` yourself.

## 10. Removing

```bash
lmnsquid rm all-students               # container, cache + log volumes, blocklist, definition
lmnsquid rm all-students --keep-logs   # same, but keeps the access-log volume lmnsquid-logs-all-students
```

The keytab in `secrets/` and the service account stay (operator-managed). When the last
instance that uses them is gone: `samba-tool user delete svc-squid` on the DC (removes the
SPN with it), `shred -u /etc/linuxmuster-squid/secrets/proxy.keytab` on the host. `apt-get
purge linuxmuster-squid` removes `/etc/linuxmuster-squid`, `/var/lib/linuxmuster-squid` and
`/opt/linuxmuster-squid`; Docker volumes of instances not removed with `lmnsquid rm` stay.

## Change log of the definitions

```bash
git -C /var/lib/linuxmuster-squid/instances log --oneline    # one commit per create/edit/update/rm
```
