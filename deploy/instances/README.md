<!--
SPDX-FileCopyrightText: Kevin Stenzel
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Instance definitions (declarative)

One file = **one Squid instance** (school × role). The control plane (P4) reads
these YAMLs, renders the container env from them (see `image/entrypoint.sh`) and
reconciles the actual against the desired state. File name convention:
`<school>-<role>.yaml`.

## Fields

| Field | Meaning |
|---|---|
| `school` | School shortname/OU. `default-school` = **unprefixed**. |
| `role` | `teachers` \| `students`. |
| `ad_group` | AD group for the ACL. **Prefix rule:** default-school → `teachers`/`students`; every other school → `<school>-teachers`/`<school>-students`. |
| `realm` | Kerberos realm (UPPERCASE of the AD DNS domain). |
| `visible_hostname` | Proxy FQDN (== SPN host; clients configure exactly this one). |
| `http_port` | Container-internal port (the control plane maps the host port). |
| `school_subnets` | `src` ACL: client subnets of this school (space-separated). |
| `keytab_secret` | Name of the mounted keytab secret. |
| `cache_size_mb` | Cache size. |
| `image` | **Digest-pinned** image (`…@sha256:…`, P5). |

**Verified (P3, crabbox E2E):** two instances with different `ad_group`
(default `teachers` vs. `schule2-teachers`) isolate cleanly — the teacher of one
school is rejected at the other's instance (403), and allowed at their own (200).
