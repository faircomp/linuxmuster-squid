#!/bin/sh
# Container healthcheck: ask the local cache manager for status.
# The manager interface is exposed to localhost only (see squid.conf.template).
squidclient -T 3 -h 127.0.0.1 -p "${HTTP_PORT:-3128}" mgr:info 2>/dev/null \
    | grep -qF '200 OK'
