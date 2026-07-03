<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Keytab- & DNS-Anforderungen

Der Proxy authentifiziert Clients per Kerberos und braucht dafür einen **Keytab**
mit dem Service-Principal `HTTP/<proxy-fqdn>`. Verifiziert (P1-E2E, [ADR-007](decisions.md)):
Der Keytab muss **einen kinit-fähigen Account-Principal** enthalten (nicht nur den
HTTP-SPN-Alias), weil der Gruppen-Helper `ext_kerberos_ldap_group_acl` sich damit
per GSSAPI am LDAP anmeldet. Negotiate läuft mit `-s GSS_C_NO_NAME` und entschlüsselt
die `HTTP/<fqdn>`-Tickets über denselben Account-Schlüssel.

## Keytab erzeugen (durch den AD-Admin)

**Standard (ADR-009):** der Admin liefert den Keytab; die Control-Plane provisioniert
**nicht** selbst (least privilege). Drei belegte Wege:

1. **Domänenmitglied + `net ads` (empfohlen für Produktion).** Proxy-Host der Domäne
   beitreten, dann Maschinenkonto-Keytab (kinit-fähig):
   ```
   kinit administrator@REALM
   export KRB5_KTNAME=FILE:/etc/squid/HTTP.keytab
   net ads keytab CREATE
   net ads keytab ADD HTTP
   ```
2. **`msktutil` mit dediziertem Computerkonto** (+ nächtlicher `msktutil --auto-update`
   gegen Passwort-Rotation) — sauberer Lifecycle, wenn der Host Domänenmitglied ist.
3. **Service-Account + `samba-tool` (wie im E2E).** Ein kinit-fähiges Konto anlegen,
   SPN anhängen, dessen Keytab exportieren — siehe `scripts/provision-keytab.sh`.

## Keytab an die Instanz geben

- Als **Docker-Secret** ablegen: Datei in `secrets_dir` (Default
  `/etc/linuxmuster-squid/secrets`), Dateiname == `keytab_secret` der Instanz.
  Die Control-Plane mountet sie **read-only** unter `/run/secrets/<keytab_secret>`
  (= `KEYTAB` im Container).
- **Rechte:** `0600` auf dem Host; im Container muss `cache_effective_user proxy`
  sie lesen können (Secret-Mount ist world-readable/tmpfs). **Nie ins Env/Log.**
- **Pro Instanz getrennt** — kein geteilter Keytab über Schulen hinweg.
- **Rotation:** `net ads`-Keytabs werden durch Maschinenpasswort-Rotation ungültig
  → `msktutil --auto-update` oder neu exportieren; Service-Account-Keytabs bei
  Passwortwechsel neu exportieren. Nach Rotation Instanz neu erstellen (Secret neu
  mounten) bzw. `restart`.

## DNS- & Zeit-Anforderungen (hart)

- **A-Record** für jeden Proxy-FQDN (`visible_hostname`).
- **Vorwärts+Rückwärts-DNS** ODER `rdns = false` — das Image generiert bereits
  `/etc/krb5.conf` mit `rdns=false` + `/etc/ldap/ldap.conf` `SASL_NOCANON on`, sodass
  der `ldap/`-SPN aus dem literalen DC-Namen gebildet wird (nicht per PTR).
- **Kein `wpad`-PTR** — bricht SSO für Firefox/Chromium auf Linux.
- **NTP** synchron zum DC (Kerberos-Skew < 5 min).
- Clients müssen den Proxy per **FQDN**, nie per IP erreichen (sonst kein Kerberos).

Siehe auch: [`architecture.md`](architecture.md), [`decisions.md`](decisions.md) (ADR-007/008/009).
