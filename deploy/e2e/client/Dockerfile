# Kerberos-Test-Client: kinit + curl --proxy-negotiate.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends krb5-user curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY krb5.conf /etc/krb5.conf
COPY assert.sh /assert.sh
RUN chmod 0755 /assert.sh
ENTRYPOINT ["/assert.sh"]
