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
# dropped here (the dotted parent matches them anyway) and reported on stderr (docker logs).
set -eu

SRC=/etc/squid/lists
DST=/run/lmnsquid/lists
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

# sync <name>: a missing file becomes an empty list.
sync_list() {
    name=$1 src="${SRC}/$1" tmp="${DST}/.$1.tmp"
    if [ -f "${src}" ]; then
        uncovered < "${src}" 2>"${DST}/.$1.covered" | sort > "${tmp}"
    else
        : > "${tmp}"
        [ "${name}" = noauth.domains ] \
            && echo "linuxmuster-squid: no ${src}, domains without proxy auth: none" >&2
    fi
    if [ -s "${DST}/.$1.covered" ]; then
        echo "linuxmuster-squid: ${name}: $(wc -l < "${DST}/.$1.covered") entries ignored, already covered by a listed parent domain:" \
            "$(head -5 "${DST}/.$1.covered" | tr '\n' ' ')" >&2
    fi
    rm -f "${DST}/.$1.covered"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${DST}/${name}"
}

sync_list blocked.domains
sync_list noauth.domains
