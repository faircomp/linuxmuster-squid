# linuxmuster-squid — data-plane image
# One generic image, driven entirely by env + mounted secrets. N instances
# (one per school x role) are just N containers of this image.
#
# We install `squid-openssl` (NOT the default `squid`): on Ubuntu 24.04 the plain
# `squid` package is built WITHOUT OpenSSL, so ssl_bump / peek-splice (needed for
# SNI filtering in P2) are impossible with it. `squid-openssl` provides the full
# SSL feature set AND still ships every Kerberos/LDAP helper we use. `squidclient`
# is a separate package (used by the healthcheck).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      squid-openssl \
      squidclient \
      krb5-user \
      gettext-base \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/squid/lists /etc/squid/templates /var/log/squid /var/spool/squid \
 && chown -R proxy:proxy /var/log/squid /var/spool/squid \
 && : > /etc/squid/lists/blocked.domains

# Fail the build early if a helper we rely on is missing (all verified present in
# the noble squid-openssl / squidclient packages). NOTE: ntlm_auth (if ever needed
# for a fallback) is /usr/bin/ntlm_auth from the `winbind` package — it does NOT
# live under /usr/lib/squid, so do not assert it here.
RUN set -eu; for b in \
      /usr/lib/squid/negotiate_kerberos_auth \
      /usr/lib/squid/ext_kerberos_ldap_group_acl \
      /usr/lib/squid/ext_ldap_group_acl \
      /usr/lib/squid/security_file_certgen \
      /usr/bin/squidclient ; do \
      test -x "$b" || { echo "MISSING helper: $b" >&2; exit 1; }; \
    done

COPY templates/squid.conf.template /etc/squid/templates/squid.conf.template
COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY healthcheck.sh  /usr/local/bin/healthcheck.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

EXPOSE 3128
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD /usr/local/bin/healthcheck.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
