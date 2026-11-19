# SPDX-FileCopyrightText: Kevin Stenzel
#
# SPDX-License-Identifier: GPL-3.0-or-later

# Kerberos-Test-Client: kinit + curl --proxy-negotiate; faketime (libfaketime) runs curl
# with a client clock ahead of the proxy's (clock skew cases, ADR-017).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends krb5-user curl ca-certificates openssl faketime \
 && rm -rf /var/lib/apt/lists/*
COPY krb5.conf /etc/krb5.conf
COPY assert.sh /assert.sh
RUN chmod 0755 /assert.sh
ENTRYPOINT ["/assert.sh"]
