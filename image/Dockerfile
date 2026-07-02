# linuxmuster-squid — data-plane image
# One generic image, driven entirely by env + mounted secrets. N instances
# (one per school x role) are just N containers of this image.
#
# Built FROM ubuntu:24.04 on purpose: the official `ubuntu/squid` image is
# Pebble-managed, which fights a custom envsubst entrypoint. The Ubuntu
# `squid` package already ships the Kerberos Negotiate helper and the
# LDAP/Kerberos group ACL helpers we need.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      squid \
      krb5-user \
      gettext-base \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/squid/lists /etc/squid/templates \
 && : > /etc/squid/lists/blocked.domains
# Sanity check: the Kerberos + group ACL helpers must be present in the image.
RUN test -x /usr/lib/squid/negotiate_kerberos_auth \
 && test -x /usr/lib/squid/ext_kerberos_ldap_group_acl

COPY templates/squid.conf.template /etc/squid/templates/squid.conf.template
COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY healthcheck.sh  /usr/local/bin/healthcheck.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

EXPOSE 3128

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
