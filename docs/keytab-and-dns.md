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

**Standard (ADR-009): KEIN Domänen-Join.** Weder der Proxy-Host noch die Container treten
der Domäne bei. Der AD-Admin erzeugt den Keytab **einmalig auf dem DC** und liefert die
Datei; die Control-Plane provisioniert **nicht** selbst (least privilege).

1. **Empfohlen — Service-Account + `samba-tool` auf dem DC (join-frei, wie im E2E bewiesen).**
   Ein kinit-fähiges Dienstkonto anlegen (existiert nur als AD-Objekt — kein Join), den
   `HTTP/<proxy-fqdn>`-SPN anhängen, dessen Keytab exportieren → Datei ins `secrets_dir`.
   Siehe `scripts/provision-keytab.sh` (prüft Duplicate-SPN, idempotent).
2. *(Alternative, nur falls der Proxy-Host ohnehin Domänenmitglied ist.)* `net ads keytab`
   bzw. `msktutil` (mit `--auto-update` gegen Passwort-Rotation) nutzt den Maschinenkonto-
   Keytab. Für das reine Container-Modell **nicht nötig** — und ein Join pro Instanz wäre
   sogar kontraproduktiv (Maschinenkonto-Rotation macht Keytabs stale).

## Keytab an die Instanz geben

- Als **Docker-Secret** ablegen: Datei in `secrets_dir` (Default
  `/etc/linuxmuster-squid/secrets`), Dateiname == `keytab_secret` der Instanz.
  Die Control-Plane mountet sie **read-only** unter `/run/secrets/<keytab_secret>`
  (= `KEYTAB` im Container).
- **Rechte:** `0600` auf dem Host, read-only gemountet. Der Container-Entrypoint (als
  root, mit `DAC_OVERRIDE`) kopiert den Keytab einmalig nach `/run/lmnsquid/keytab`
  (proxy-lesbar, `0600`), damit der als `proxy` laufende Squid ihn lesen kann — der
  gemountete Keytab bleibt `0600`. **Nie ins Env/Log.**
- **Pro Instanz getrennt** — kein geteilter Keytab über Schulen hinweg.
- **Rotation:** `net ads`-Keytabs werden durch Maschinenpasswort-Rotation ungültig
  → `msktutil --auto-update` oder neu exportieren; Service-Account-Keytabs bei
  Passwortwechsel neu exportieren. Nach Rotation Instanz neu erstellen (Secret neu
  mounten) bzw. `restart`.

## KVNO- & SPN-Fallstricke (verifiziert)

- **Keytab mehrfach exportieren ist harmlos** — `samba-tool domain exportkeytab` schreibt
  die *aktuellen* Schlüssel, ändert **kein** Passwort und **bumpt die KVNO nicht**. ABER es
  **hängt an** eine bestehende Datei an → deshalb macht `provision-keytab.sh` `rm -f` vor dem
  Export (sonst sammeln sich veraltete KVNO-Einträge und Squid greift evtl. den falschen).
- **Passwort-Reset / Neu-Join (gleicher Name) macht alte Keytabs ungültig** — jeder Reset
  erhöht die KVNO (`msDS-KeyVersionNumber`); alte Keytabs werden stale (`KRB_AP_ERR_MODIFIED`
  bzw. „matching key not found in keytab"). → Keytab **neu exportieren** und Instanz neu
  mounten/`restart`.
- **Derselbe SPN auf zwei Konten = Bruch** — ein SPN (`HTTP/<fqdn>`) muss domänenweit
  **eindeutig** sein, sonst kann der KDC nicht disambiguieren (`KRB_AP_ERR_MODIFIED`, oft
  NTLM-Fallback). `provision-keytab.sh` prüft das vorab (`ldbsearch`) und ist idempotent;
  manuell prüfen: `setspn -X` (Windows) bzw.
  `ldbsearch -H .../sam.ldb '(servicePrincipalName=HTTP/<fqdn>)' sAMAccountName` (Samba).

## DNS- & Zeit-Anforderungen (hart)

- **A-Record** für jeden Proxy-FQDN (`visible_hostname`).
- **Vorwärts+Rückwärts-DNS** ODER `rdns = false` — das Image generiert bereits
  `/etc/krb5.conf` mit `rdns=false` + `/etc/ldap/ldap.conf` `SASL_NOCANON on`, sodass
  der `ldap/`-SPN aus dem literalen DC-Namen gebildet wird (nicht per PTR).
- **Kein `wpad`-PTR** — bricht SSO für Firefox/Chromium auf Linux.
- **NTP** synchron zum DC (Kerberos-Skew < 5 min).
- Clients müssen den Proxy per **FQDN**, nie per IP erreichen (sonst kein Kerberos).

Siehe auch: [`architecture.md`](architecture.md), [`decisions.md`](decisions.md) (ADR-007/008/009).
