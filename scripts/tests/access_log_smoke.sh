#!/usr/bin/env bash
# SPDX-FileCopyrightText: Kevin Stenzel
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Smoke: der Entrypoint spiegelt den Squid-Access-Log via Tailer auf Container-stdout,
# sodass `docker logs` — und damit die Control-Plane (`lmnsquid logs` über docker-py) —
# ihn zeigt. Nutzt `docker run` (= derselbe Pfad, den die Control-Plane per docker-py
# fährt; NICHT docker-compose). Braucht Docker.
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

echo "== run container (read-only, gehärtet — wie im Produktions-Pfad) =="
$D run -d --name "$NAME" \
    --read-only --tmpfs /run --tmpfs /tmp --tmpfs /var/log/squid --tmpfs /var/spool/squid \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add DAC_OVERRIDE --cap-add CHOWN \
    --security-opt no-new-privileges \
    -e REALM=EXAMPLE.INTERNAL -e AD_GROUP=teachers \
    -e VISIBLE_HOSTNAME=sq.example.internal -e SCHOOL_SUBNETS=0.0.0.0/0 \
    -v "$KT:/run/secrets/squid_keytab:ro" \
    linuxmuster-squid:alsmoke >/dev/null
sleep 8

echo "== Request anstoßen + auf Access-Log in docker logs warten (Poll, bis 25s) =="
# Poll statt fixem sleep: der Weg Tailer -> Pipe -> dockerd -> json-log hat eine variable
# Latenz; jede Runde einen Request erzeugen und docker logs prüfen.
ok=0
for _ in $(seq 1 25); do
    $D exec "$NAME" squidclient -h 127.0.0.1 -p 3128 http://probe.invalid/ >/dev/null 2>&1 || true
    if $D logs "$NAME" 2>&1 | grep -qaE 'TCP_|GET http'; then ok=1; break; fi
    sleep 1
done
if [ "$ok" = 1 ]; then
    echo "  [PASS] Squid-Access-Log erscheint in docker logs"
else
    echo "  [FAIL] Access-Log NICHT in docker logs"; fail=1
    echo "  --- docker logs (Auszug) ---"; $D logs "$NAME" 2>&1 | tail -10 | sed 's/^/    /'
fi

echo "== access-log smoke: $fail Fehler =="
exit "$fail"
