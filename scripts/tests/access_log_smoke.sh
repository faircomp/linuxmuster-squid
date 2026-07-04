#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke: the entrypoint mirrors the Squid access log via a tailer onto the container stdout,
# so that `docker logs` — and thus the control plane (`lmnsquid logs` via docker-py) —
# shows it. Uses `docker run` (= the same path the control plane drives via docker-py;
# NOT docker-compose). Needs Docker.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D="docker"; docker info >/dev/null 2>&1 || D="sudo docker"
NAME="lmnsquid-alsmoke"
KT="/tmp/alsmoke.keytab"
fail=0

cleanup(){ $D rm -f "$NAME" >/dev/null 2>&1 || true; rm -f "$KT"; }
trap cleanup EXIT

echo "== build image =="
$D build -t linuxmuster-squid:alsmoke "$ROOT/image" >/dev/null 2>&1 \
    || { echo "build failed"; $D build -t linuxmuster-squid:alsmoke "$ROOT/image"; exit 1; }

printf 'dummy-keytab-content' > "$KT"; chmod 600 "$KT"
$D rm -f "$NAME" >/dev/null 2>&1 || true

echo "== run container (read-only, hardened — like in the production path) =="
$D run -d --name "$NAME" \
    --read-only --tmpfs /run --tmpfs /tmp --tmpfs /var/log/squid --tmpfs /var/spool/squid \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE --cap-add CHOWN \
    --security-opt no-new-privileges \
    -e REALM=EXAMPLE.INTERNAL -e AD_GROUP=teachers \
    -e VISIBLE_HOSTNAME=sq.example.internal -e SCHOOL_SUBNETS=0.0.0.0/0 \
    -v "$KT:/run/secrets/squid_keytab:ro" \
    linuxmuster-squid:alsmoke >/dev/null
sleep 8

echo "== trigger request + wait for access log in docker logs (poll, up to 25s) =="
# Poll instead of a fixed sleep: the path tailer -> pipe -> dockerd -> json-log has a variable
# latency; each round generate a request and check docker logs.
ok=0
for _ in $(seq 1 25); do
    $D exec "$NAME" squidclient -h 127.0.0.1 -p 3128 http://probe.invalid/ >/dev/null 2>&1 || true
    if $D logs "$NAME" 2>&1 | grep -qaE 'TCP_|GET http'; then ok=1; break; fi
    sleep 1
done
if [ "$ok" = 1 ]; then
    echo "  [PASS] Squid access log appears in docker logs"
else
    echo "  [FAIL] access log NOT in docker logs"; fail=1
    echo "  --- docker logs (excerpt) ---"; $D logs "$NAME" 2>&1 | tail -10 | sed 's/^/    /'
fi

echo "== access-log smoke: $fail failures =="
exit "$fail"
