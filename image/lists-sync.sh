#!/bin/sh

# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Builds the domain lists squid reads (/run/lmnsquid/lists/) from the mounted ones
# (/etc/squid/lists/, read-only, maintained by the control plane, an editor or
# blocklist-refresh.sh). Run by the entrypoint before squid starts and by `lmnsquid ...
# reload` before `squid -k reconfigure`, so a list squid cannot load never reaches it:
# squid 6 stops with "FATAL: Bungled ... acl ... dstdomain" when a list holds a name that
# another entry already covers and comes first (".a.example.org" before ".example.org",
# or "example.org" next to ".example.org"); measured with squid 6.14. Such names are
# dropped here (the dotted parent matches them anyway). For the noauth list (ADR-016)
# entries that are not host names with at least two labels and a non-numeric last label
# (IP literals, numeric forms, single labels like "com") are dropped as well: they would
# open far more than a domain. Dropped entries are reported on stderr (docker logs).
set -eu

# (Overridable only so that controlplane/tests/test_lists_sync.py can run this file as is.)
SRC="${LISTS_SYNC_SRC:-/etc/squid/lists}"
DST="${LISTS_SYNC_DST:-/run/lmnsquid/lists}"
mkdir -p "${DST}"
chmod 0755 "${DST}"

# Comments, blank lines and everything after the first word dropped, lower-cased, trailing
# dots removed; then every entry that a dotted entry covers. Same program as in
# scripts/blocklist-refresh.sh.
uncovered() {
    awk '
    { sub(/\r$/, ""); sub(/#.*/, ""); e = tolower($1); sub(/\.+$/, "", e)
      if (e == "" || e == "." || (e in seen)) next
      seen[e] = 1; order[++n] = e
      if (substr(e, 1, 1) == ".") dotted[e] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        e = order[i]; s = e; covered = 0
        if (substr(e, 1, 1) == ".") s = substr(e, 2)
        else if (("." e) in dotted) covered = 1
        while (!covered && (p = index(s, ".")) > 0) {
          s = substr(s, p + 1)
          if (("." s) in dotted) covered = 1
        }
        if (covered) print e > "/dev/stderr"; else print e
      }
    }'
}

# sync <name> <kind>: kind "noauth" also drops what is not a multi-label host name, and a
# name whose labels are all inet_aton numbers (decimal, octal, 0x-hex: 1.2.3.0x4, 0x7f.0x1),
# i.e. an IPv4 address in any notation (same rule as normalize_noauth_domain in Python).
sync_list() {
    name=$1 kind=$2 src="${SRC}/$1" tmp="${DST}/.$1.tmp"
    if [ ! -f "${src}" ]; then
        : > "${tmp}"
        [ "${kind}" = noauth ] \
            && echo "linuxmuster-squid: no ${src}, domains without proxy auth: none" >&2
    elif [ "${kind}" = noauth ]; then
        sed -e 's/#.*//' "${src}" \
            | awk '{ gsub(/\r/, ""); e = tolower($1); sub(/\.+$/, "", e); if (e != "") print e }' \
            | awk -v list="${name}" '
                function numeric(name,    n, i, l) {
                    n = split(name, l, ".")
                    for (i = 1; i <= n; i++)
                        if (l[i] != "" && l[i] !~ /^(0x[0-9a-f]*|[0-9]+)$/) return 0
                    return 1
                }
                /^\.?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z0-9-]*[a-z][a-z0-9-]*$/ && !numeric($0) { print; next }
                { print "linuxmuster-squid: " list ": ignored, not a domain name: " $0 > "/dev/stderr" }' \
            | uncovered 2>"${DST}/.$1.covered" | sort > "${tmp}"
    else
        uncovered < "${src}" 2>"${DST}/.$1.covered" | sort > "${tmp}"
    fi
    if [ -s "${DST}/.$1.covered" ]; then
        echo "linuxmuster-squid: ${name}: $(wc -l < "${DST}/.$1.covered") entries ignored, already covered by a listed parent domain:" \
            "$(head -5 "${DST}/.$1.covered" | tr '\n' ' ')" >&2
    fi
    rm -f "${DST}/.$1.covered"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${DST}/${name}"
}

sync_list blocked.domains blocklist
sync_list noauth.domains noauth
