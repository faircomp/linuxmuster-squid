#!/bin/sh
# Container-Healthcheck: eine normale Proxy-Anfrage MUSS 407 (Proxy Auth Required)
# liefern — das beweist, dass Squid lebt UND die Kerberos-Auth erzwingt.
# (Kein cache-manager: dessen Anfrage würde auf den eigenen visible_hostname
#  zeigen und eine "Forwarding loop"-Warnung auslösen.)
squidclient -T 3 -h 127.0.0.1 -p "${HTTP_PORT:-3128}" http://healthcheck.invalid/ 2>/dev/null \
    | grep -q '407'
