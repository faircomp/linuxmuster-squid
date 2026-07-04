#!/bin/sh

# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Container healthcheck: a normal proxy request MUST return 407 (Proxy Auth
# Required) — this proves that Squid is alive AND enforces Kerberos auth.
# (No cache-manager: its request would point at the proxy's own visible_hostname
#  and trigger a "Forwarding loop" warning.)
squidclient -T 3 -h 127.0.0.1 -p "${HTTP_PORT:-3128}" http://healthcheck.invalid/ 2>/dev/null \
    | grep -q '407'
