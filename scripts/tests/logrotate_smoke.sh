#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke: the access log on a persistent volume is rotated (gzip) and the
# retention (LOG_RETENTION_DAYS) takes effect. Forces rotation via `logrotate -f` (instead
# of waiting a day). Needs Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="docker"; docker info >/dev/null 2>&1 || D="sudo docker"
NAME="lmnsquid-lrsmoke"
VOL="lmnsquid-lrsmoke-logs"
KT="/tmp/lrsmoke.keytab"
fail=0

cleanup(){ $D rm -f "$NAME" >/dev/null 2>&1 || true; $D volume rm "$VOL" >/dev/null 2>&1 || true; rm -f "$KT"; }
trap cleanup EXIT

echo "== build image =="
$D build -t linuxmuster-squid:lrsmoke "$ROOT/image" >/dev/null 2>&1 \
    || { echo "build failed"; $D build -t linuxmuster-squid:lrsmoke "$ROOT/image"; exit 1; }
printf 'dummy-keytab' > "$KT"; chmod 600 "$KT"
$D rm -f "$NAME" >/dev/null 2>&1 || true; $D volume rm "$VOL" >/dev/null 2>&1 || true

echo "== run container (persistent log volume, LOG_RETENTION_DAYS=2) =="
$D run -d --name "$NAME" \
    --read-only --tmpfs /run --tmpfs /tmp --tmpfs /var/spool/squid \
    -v "$VOL:/var/log/squid" \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE --cap-add CHOWN \
    --security-opt no-new-privileges \
    -e REALM=EXAMPLE.INTERNAL -e AD_GROUP=teachers -e VISIBLE_HOSTNAME=sq.example.internal \
    -e LOG_RETENTION_DAYS=2 \
    -v "$KT:/run/secrets/squid_keytab:ro" \
    linuxmuster-squid:lrsmoke >/dev/null
sleep 8

gen(){ $D exec "$NAME" squidclient -h 127.0.0.1 -p 3128 http://probe.invalid/ >/dev/null 2>&1 || true; }
rot(){ $D exec "$NAME" logrotate -f -s /var/log/squid/.logrotate.state /run/lmnsquid/logrotate.conf 2>/dev/null || true; }

echo "== 3x generate + rotate (retention=2 -> access.log.3* must not remain) =="
for _ in 1 2 3; do gen; sleep 1; rot; sleep 1; done

echo "== files in /var/log/squid =="
$D exec "$NAME" ls -1 /var/log/squid 2>/dev/null | sed 's/^/  /'

if $D exec "$NAME" sh -c 'ls /var/log/squid/access.log.*.gz >/dev/null 2>&1'; then
    echo "  [PASS] rotated gzip file present"
else
    echo "  [FAIL] no gzip rotation"; fail=1
fi
if $D exec "$NAME" sh -c 'ls /var/log/squid/access.log.3* >/dev/null 2>&1'; then
    echo "  [FAIL] retention not taking effect (access.log.3* exists)"; fail=1
else
    echo "  [PASS] retention: access.log.3* not present"
fi

echo "== historical query: zcat over current + rotated + gz (like access_logs()) =="
if $D exec "$NAME" sh -c 'zcat -f /var/log/squid/access.log* 2>/dev/null | grep -Fq "GET"'; then
    echo "  [PASS] access history queryable over rotated+gz files"
else
    echo "  [FAIL] historical query finds nothing"; fail=1
fi

echo "== logrotate smoke: $fail errors =="
exit "$fail"
