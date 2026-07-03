<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Instanz-Definitionen (deklarativ)

Je Datei = **eine Squid-Instanz** (Schule × Rolle). Die Control-Plane (P4) liest
diese YAMLs, rendert daraus die Container-Env (siehe `image/entrypoint.sh`) und
reconciled den Ist- gegen den Sollzustand. Dateiname-Konvention:
`<schule>-<rolle>.yaml`.

## Felder

| Feld | Bedeutung |
|---|---|
| `school` | Schulkürzel/OU. `default-school` = **unpräfixiert**. |
| `role` | `teachers` \| `students`. |
| `ad_group` | AD-Gruppe für die ACL. **Präfix-Regel:** default-school → `teachers`/`students`; jede andere Schule → `<schule>-teachers`/`<schule>-students`. |
| `realm` | Kerberos-Realm (UPPERCASE der AD-DNS-Domain). |
| `visible_hostname` | Proxy-FQDN (== SPN-Host; Clients konfigurieren genau diesen). |
| `http_port` | Container-interner Port (Host-Port mappt die Control-Plane). |
| `school_subnets` | `src`-ACL: Client-Subnetze dieser Schule (Leerzeichen-getrennt). |
| `keytab_secret` | Name des gemounteten Keytab-Secrets. |
| `cache_size_mb` | Cache-Größe. |
| `image` | **Digest-gepinntes** Image (`…@sha256:…`, P5). |

**Verifiziert (P3, crabbox-E2E):** zwei Instanzen mit unterschiedlicher `ad_group`
(default `teachers` vs. `schule2-teachers`) isolieren sauber — der Lehrer der einen
Schule wird an der Instanz der anderen abgewiesen (403), am eigenen zugelassen (200).
