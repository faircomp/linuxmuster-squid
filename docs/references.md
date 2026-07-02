<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Referenzen & verifizierte Fakten

Belegte Grundlagen samt Quellen. Vor dem Implementieren eines Formats/Verhaltens
die jeweilige **offizielle** Quelle erneut ziehen (siehe `CLAUDE.md`). Erhebung per
Recherche-Workflows am **2026-07-02** (Confidence in Klammern).

## linuxmuster.net 7 — Architektur & Identität

- Aktuell **7.3** (09/2025, Ubuntu 24.04); Samba AD DC + OPNsense + Sophomorix. (high)
  — https://www.linuxmuster.net/de/2025/09/15/linuxmuster-net-7-3-release-verbesserte-skalierbarkeit-und-modularisierung/
- Multischool: OUs unter `OU=SCHOOLS`; `default-school` unpräfixiert; Bind-User unter
  `OU=Management,OU=GLOBAL`. (high)
  — https://docs.linuxmuster.net/de/latest/external-services/nextcloud/authentication.html
- Rollen im Attribut `sophomorixRole`; Gruppe `teachers` / `<schule>-teachers`
  (default-school ohne Präfix). (high)
  — https://github.com/linuxmuster/sophomorix4/wiki/objectClasses
- Netz `10.0.0.0/16`, Server `10.0.0.1`, OPNsense-Gateway `10.0.0.254`; Subnetze in
  `/etc/linuxmuster/subnets.csv`. (high)
  — https://docs.linuxmuster.net/de/latest/systemadministration/network/networksegmentation/networksegmentation.html
- Prüfungsmodus: `<user>-exam`-Konto, Proxy deaktiviert. (high)
  — https://docs.linuxmuster.net/de/latest/classroom/exam-and-transfer.html

## Bestehender Proxy (Lücke)

- v7-Proxy = Squid **in OPNsense**, Kerberos-SSO via `os-web-proxy-sso` — abgekündigt
  ab OPNsense 26.1, unmaintained; Gruppen-Policy nur über Community-Plugin; keine
  Multischool-Isolation. (high)
  — https://ask.linuxmuster.net/t/frage-zu-os-web-proxy-sso-plugin-veraltet-ab-opnsense-26-1-abgekuendigt/11250
  — https://wiki.linuxmuster.net/community/anwenderwiki:firewall_lmn7:squidproxy:start

## Squid — Kerberos/GSSAPI (Negotiate)

- `negotiate_kerberos_auth` (-k Keytab, -s SPN/`GSS_C_NO_NAME`); Keytab via
  `KRB5_KTNAME`. (high)
  — https://wiki.squid-cache.org/ConfigExamples/Authenticate/Kerberos
- SPN `HTTP/<fqdn>@REALM` (Realm UPPERCASE); fwd+rev DNS + NTP<5min Pflicht;
  FQDN statt IP. (high)
  — https://wiki.squid-cache.org/ConfigExamples/Authenticate/WindowsActiveDirectory
- **Proxy-Auth im Intercept-Modus unmöglich** → expliziter Forward-Proxy. (high)
  — https://wiki.squid-cache.org/Features/Authentication
- Client-`krb5.conf` `rdns=false` + `dns_canonicalize_hostname=false` umgeht
  PTR-Zwang. (high) — https://web.mit.edu/kerberos/krb5-devel/doc/admin/princ_dns.html

## Squid — Gruppen-Autorisierung (AD)

- `ext_kerberos_ldap_group_acl` (nutzt Ticket, `-g Group@Realm`, rekursiv `-m`,
  DC-Discovery via SRV) bzw. `ext_ldap_group_acl` (expliziter Bind, GC 3268). (high)
  — https://manpages.opensuse.org/Tumbleweed/squid/ext_kerberos_ldap_group_acl.8
  — https://manpages.ubuntu.com/manpages/jammy/man8/ext_ldap_group_acl.8.html
- Externe-ACL-Caching `ttl/negative_ttl/grace`. (high)
  — https://www.squid-cache.org/Doc/config/external_acl_type/
- ⚠️ `%u` vs. `%v`-Platzhalter build-abhängig → am realen Helper testen.

## Squid — Paketierung (Ubuntu 24.04)

- **SSL/`ssl_bump`/peek-splice nur in `squid-openssl`**, NICHT im Paket `squid`
  (kein `security_file_certgen`). Beide enthalten die Kerberos/LDAP-Helfer. (high)
  — https://packages.ubuntu.com/noble/amd64/squid/filelist
  — https://packages.ubuntu.com/noble/amd64/squid-openssl/filelist
- `squidclient` = eigenes Paket; `ntlm_auth` kommt aus `winbind` (`/usr/bin/ntlm_auth`,
  NICHT `/usr/lib/squid/`). (high)
  — https://packages.ubuntu.com/noble/squidclient
- SNI peek+splice ohne Entschlüsselung; Wegwerf-CA für den Peek-Schritt, nie an
  Clients verteilt. (high / medium bzgl. strikter cert-Pflicht bei splice-only)
  — https://wiki.squid-cache.org/Features/SslPeekAndSplice
- Fallback CONNECT-`dstdomain` (kein SSL nötig). (high)
  — https://wiki.squid-cache.org/SquidFaq/SquidAcl

## Kerberos-E2E im Container (Test)

- Samba-AD-DC via `samba-tool domain provision` bzw. `nowsci/samba-domain`
  (`NOCOMPLEXITY=true`). (high) — https://ubuntu.com/server/docs/how-to/samba/provision-samba-ad-controller/
- Keytab DC-seitig: `samba-tool spn add HTTP/<fqdn> <acct>` +
  `samba-tool domain exportkeytab --principal=HTTP/<fqdn>`. (high)
  — https://wiki.samba.org/index.php/Generating_Keytabs
- Client treibt Negotiate: `curl --proxy http://<fqdn>:3128 --proxy-negotiate -U : <url>`
  nach `kinit`; Beweis über Codes 200/403/403/407. (high)
  — https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/7/html/networking_guide/setting-up-squid-as-a-caching-proxy-with-kerberos-authentication

## Client-Steuerung (GPO)

- Edge/Chrome `ProxySettings=fixed_servers`; Firefox `policies.json`
  `Proxy`+`Authentication.SPNEGO`. (high)
  — https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/proxysettings
  — https://mozilla.github.io/policy-templates/
- Stilles SSO: Proxy-FQDN in Local-Intranet-Zone (Site-to-Zone) oder
  `AuthServerAllowlist`; per-Rolle via Security-Filtering/GPP-Item-Level-Targeting.
  Kerberos-Delegation geht nicht für Proxy-Auth. (high)
  — https://learn.microsoft.com/en-us/deployedge/per-site-configuration-by-policy
- Kein `wpad`-PTR (bricht Linux-SSO). (high)
  — https://wiki.linuxmuster.net/community/anwenderwiki:firewall_lmn7:squidproxy:start

## Control-Plane & Updates

- linuxmuster-api7 ist selbst FastAPI/uvicorn (Ökosystem-Nähe). (high)
  — https://github.com/linuxmuster/linuxmuster-api
- Docker-Lifecycle via docker-py (`docker`≥7), pull-by-Digest; Socket = root-äquivalent.
  (high) — https://docker-py.readthedocs.io/ · https://docs.docker.com/engine/install/linux-postinstall/
- Watchtower **archiviert 2025-12-17** (kein Rollback) → nicht nutzen; Renovate pinnt
  Digests in Compose. (high)
  — https://github.com/containrrr/watchtower · https://docs.renovatebot.com/docker/
- `.deb` reproduzierbar via dh-virtualenv (kein pip-in-postinst). (high)
  — https://dh-virtualenv.readthedocs.io/en/latest/

## Roh-Erhebungen (Task-Outputs)

- Architektur-Workflow: `wf_a9c1bd93-8a6` · Roadmap-Verifikation: `wf_322b99df-78b`
  (vollständige Fakten + Confidence + Evidence in den jeweiligen Task-Outputs).
