<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# References & verified facts

Documented foundations together with sources. Before implementing a format/behavior,
pull the respective **official** source again (see `CLAUDE.md`). Collected via
research workflows on **2026-07-02** (confidence in parentheses).

## linuxmuster.net 7 — architecture & identity

- Currently **7.3** (09/2025, Ubuntu 24.04); Samba AD DC + OPNsense + Sophomorix. (high)
  — https://www.linuxmuster.net/de/2025/09/15/linuxmuster-net-7-3-release-verbesserte-skalierbarkeit-und-modularisierung/
- Multischool: OUs under `OU=SCHOOLS`; `default-school` unprefixed; bind user under
  `OU=Management,OU=GLOBAL`. (high)
  — https://docs.linuxmuster.net/de/latest/external-services/nextcloud/authentication.html
- Roles in the `sophomorixRole` attribute; group `teachers` / `<schule>-teachers`
  (default-school without prefix). (high)
  — https://github.com/linuxmuster/sophomorix4/wiki/objectClasses
- Network `10.0.0.0/16`, server `10.0.0.1`, OPNsense gateway `10.0.0.254`; subnets in
  `/etc/linuxmuster/subnets.csv`. (high)
  — https://docs.linuxmuster.net/de/latest/systemadministration/network/networksegmentation/networksegmentation.html
- Exam mode: `<user>-exam` account, proxy disabled. (high)
  — https://docs.linuxmuster.net/de/latest/classroom/exam-and-transfer.html

## Existing proxy (gap)

- v7 proxy = Squid **in OPNsense**, Kerberos SSO via `os-web-proxy-sso` — deprecated
  as of OPNsense 26.1, unmaintained; group policy only via community plugin; no
  multischool isolation. (high)
  — https://ask.linuxmuster.net/t/frage-zu-os-web-proxy-sso-plugin-veraltet-ab-opnsense-26-1-abgekuendigt/11250
  — https://wiki.linuxmuster.net/community/anwenderwiki:firewall_lmn7:squidproxy:start

## Squid — Kerberos/GSSAPI (Negotiate)

- `negotiate_kerberos_auth` (-k keytab, -s SPN/`GSS_C_NO_NAME`); keytab via
  `KRB5_KTNAME`. (high)
  — https://wiki.squid-cache.org/ConfigExamples/Authenticate/Kerberos
- SPN `HTTP/<fqdn>@REALM` (realm UPPERCASE); fwd+rev DNS + NTP<5min mandatory;
  FQDN instead of IP. (high)
  — https://wiki.squid-cache.org/ConfigExamples/Authenticate/WindowsActiveDirectory
- **Proxy auth impossible in intercept mode** → explicit forward proxy. (high)
  — https://wiki.squid-cache.org/Features/Authentication
- Client `krb5.conf` `rdns=false` + `dns_canonicalize_hostname=false` bypasses
  the PTR requirement. (high) — https://web.mit.edu/kerberos/krb5-devel/doc/admin/princ_dns.html

## Squid — group authorization (AD)

- `ext_kerberos_ldap_group_acl` (uses the ticket, `-g Group@Realm`, recursive `-m`,
  DC discovery via SRV) resp. `ext_ldap_group_acl` (explicit bind, GC 3268). (high)
  — https://manpages.opensuse.org/Tumbleweed/squid/ext_kerberos_ldap_group_acl.8
  — https://manpages.ubuntu.com/manpages/jammy/man8/ext_ldap_group_acl.8.html
- External-ACL caching `ttl/negative_ttl/grace`. (high)
  — https://www.squid-cache.org/Doc/config/external_acl_type/
- ⚠️ `%u` vs. `%v` placeholder is build-dependent → test against the real helper.

## Squid — packaging (Ubuntu 24.04)

- **SSL/`ssl_bump`/peek-splice only in `squid-openssl`**, NOT in the `squid` package
  (no `security_file_certgen`). Both contain the Kerberos/LDAP helpers. (high)
  — https://packages.ubuntu.com/noble/amd64/squid/filelist
  — https://packages.ubuntu.com/noble/amd64/squid-openssl/filelist
- `squidclient` = separate package; `ntlm_auth` comes from `winbind` (`/usr/bin/ntlm_auth`,
  NOT `/usr/lib/squid/`). (high)
  — https://packages.ubuntu.com/noble/squidclient
- SNI peek+splice without decryption; throwaway CA for the peek step, never distributed
  to clients. (high / medium regarding strict cert requirement with splice-only)
  — https://wiki.squid-cache.org/Features/SslPeekAndSplice
- Fallback CONNECT `dstdomain` (no SSL needed). (high)
  — https://wiki.squid-cache.org/SquidFaq/SquidAcl

## Kerberos E2E in the container (test)

- Samba AD DC via `samba-tool domain provision` resp. `nowsci/samba-domain`
  (`NOCOMPLEXITY=true`). (high) — https://ubuntu.com/server/docs/how-to/samba/provision-samba-ad-controller/
- Keytab on the DC side: `samba-tool spn add HTTP/<fqdn> <acct>` +
  `samba-tool domain exportkeytab --principal=HTTP/<fqdn>`. (high)
  — https://wiki.samba.org/index.php/Generating_Keytabs
- Client drives Negotiate: `curl --proxy http://<fqdn>:3128 --proxy-negotiate -U : <url>`
  after `kinit`; proof via codes 200/403/403/407. (high)
  — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/networking_guide/setting-up-squid-as-a-caching-proxy-with-kerberos-authentication

## Client control (GPO)

- Edge/Chrome `ProxySettings=fixed_servers`; Firefox `policies.json`
  `Proxy`+`Authentication.SPNEGO`. (high)
  — https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/proxysettings
  — https://mozilla.github.io/policy-templates/
- Silent SSO: proxy FQDN in the Local Intranet zone (Site-to-Zone) or
  `AuthServerAllowlist`; per role via security filtering/GPP item-level targeting.
  Kerberos delegation does not work for proxy auth. (high)
  — https://learn.microsoft.com/en-us/deployedge/per-site-configuration-by-policy
- No `wpad` PTR (breaks Linux SSO). (high)
  — https://wiki.linuxmuster.net/community/anwenderwiki:firewall_lmn7:squidproxy:start

## Control plane & updates

- linuxmuster-api7 is itself FastAPI/uvicorn (ecosystem proximity). (high)
  — https://github.com/linuxmuster/linuxmuster-api
- Docker lifecycle via docker-py (`docker`≥7), pull-by-digest; socket = root-equivalent.
  (high) — https://docker-py.readthedocs.io/ · https://docs.docker.com/engine/install/linux-postinstall/
- Watchtower **archived 2025-12-17** (no rollback) → do not use; Renovate pins
  digests in Compose. (high)
  — https://github.com/containrrr/watchtower · https://docs.renovatebot.com/docker/
- `.deb` reproducible via dh-virtualenv (no pip-in-postinst). (high)
  — https://dh-virtualenv.readthedocs.io/en/latest/
