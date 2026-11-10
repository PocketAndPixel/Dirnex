# A Kerberos realm and a WebDAV folder that signs in by Negotiate, for M38's live checks.
#
#     docker build -t dirnex-negotiate Tooling/negotiate-standin
#
# One container holds both halves: an MIT KDC for the realm DIRNEX.TEST, and Apache with
# mod_auth_gssapi in front of mod_dav. It stands in for a Kerberos-only WebDAV share (an Apache with
# mod_auth_gssapi, or an IIS with NTLM switched off); no real Active Directory or IIS is involved
# (PLAN.md §M38, decided 2026-11-09). scripts/live_test_servers.sh starts it when the image is
# here and never builds it: the base image and the packages are a download somebody chose.
#
# Ports: 88/tcp is the KDC and 80 is Apache. The realm's principals, the folders and the log
# format are in entrypoint.sh.
FROM debian:bookworm-slim
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        krb5-kdc krb5-admin-server apache2 libapache2-mod-auth-gssapi \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 88/tcp 80/tcp
ENTRYPOINT ["/entrypoint.sh"]
