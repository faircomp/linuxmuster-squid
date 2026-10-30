#!/bin/sh

# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Squid external ACL helper (external_acl_type sni_sent ... %ssl::>sni): answers OK when the
# client sent a TLS SNI, ERR when it sent none. Used only for CONNECTs that came through
# without proxy auth (ADR-016), so that a tunnel without SNI is cut instead of being trusted
# on its CONNECT host alone. Squid sends one line per lookup: the SNI, '-' when there is none,
# followed by the ACL arguments (%DATA, again '-' without any), e.g. "- -" or
# "outlook.office.com -" (measured with squid 6.14); only the first field counts.
while read -r sni _data; do
    case "${sni}" in
        '' | '-') echo ERR ;;
        *) echo OK ;;
    esac
done
