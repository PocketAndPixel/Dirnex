#!/bin/sh
# Start the realm and the WebDAV server (see Dockerfile). Everything is made fresh per container,
# so a run never inherits a ticket, a lock or a file from the one before.
#
# Principals:
#   probe@DIRNEX.TEST        password probe-pw, the account a client signs in as
#   stranger@DIRNEX.TEST     password stranger-pw, a second account for "whose ticket was used"
#   HTTP/localhost@DIRNEX.TEST  the server's key, in Apache's keytab
#
# Locations, both mod_dav over /var/www/dav:
#   /negotiate/   Negotiate on every request (mod_auth_gssapi's default)
#   /bound/       Negotiate once per connection (GssapiConnectionBound On), as IIS keeps NTLM
#
# The access log carries the user and the connection of every request, in the format
# scripts/live_test_servers.sh gives its own Apache (`%h %{remote}p %u "%r" %>s`), so a test counts
# sign-ins from the server's side: /var/log/dirnex/dav.log, which the script mounts from the Mac.
set -eu

REALM=DIRNEX.TEST
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_kdc = false
    dns_lookup_realm = false
    rdns = false
[realms]
    $REALM = {
        kdc = 127.0.0.1:88
        admin_server = 127.0.0.1
    }
[domain_realm]
    localhost = $REALM
EOF
mkdir -p /etc/krb5kdc
cat > /etc/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_ports = 88
    kdc_tcp_ports = 88
[realms]
    $REALM = {
        database_name = /var/lib/krb5kdc/principal
        acl_file = /etc/krb5kdc/kadm5.acl
        key_stash_file = /etc/krb5kdc/stash
        max_life = 10h
        supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal
    }
[logging]
    kdc = FILE:/var/log/krb5kdc.log
EOF
: > /etc/krb5kdc/kadm5.acl
kdb5_util create -s -r "$REALM" -P dirnex-master-pw >/dev/null
kadmin.local -q "addprinc -pw probe-pw probe@$REALM" >/dev/null
kadmin.local -q "addprinc -pw stranger-pw stranger@$REALM" >/dev/null
kadmin.local -q "addprinc -randkey HTTP/localhost@$REALM" >/dev/null
kadmin.local -q "ktadd -k /etc/apache2/http.keytab HTTP/localhost@$REALM" >/dev/null
chown www-data /etc/apache2/http.keytab
krb5kdc

mkdir -p /var/www/dav/negotiate /var/www/dav/bound /var/lock/apache2/dav /var/log/dirnex
echo hello > /var/www/dav/negotiate/hello.txt
echo hello > /var/www/dav/bound/hello.txt
chown -R www-data /var/www/dav /var/lock/apache2/dav

a2enmod -q dav dav_fs auth_gssapi >/dev/null
a2dissite -q 000-default >/dev/null
cat > /etc/apache2/sites-available/dav.conf <<'EOF'
LogFormat "%h %{remote}p %u \"%r\" %>s" dav
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot /var/www/dav
    CustomLog /var/log/dirnex/dav.log dav
    DavLockDB /var/lock/apache2/dav/DavLock
    KeepAlive On
    MaxKeepAliveRequests 100
    # Debian's stock mod_dir stays on, with DirectorySlash at its default: any method naming a
    # folder without its trailing slash is answered 301, which Dirnex reads and sends again with
    # the slash (WebDAVFolderRedirect). So this is also the suite's one server that redirects, as
    # macOS's Apache in scripts/live_test_servers.sh loads no mod_dir (PLAN.md §M38).
    <Directory /var/www/dav>
        Dav On
        DavDepthInfinity Off
        Options None
        AllowOverride None
    </Directory>
    <Location /negotiate>
        AuthType GSSAPI
        AuthName "dirnex-negotiate"
        GssapiCredStore keytab:/etc/apache2/http.keytab
        GssapiAllowedMech krb5
        Require valid-user
    </Location>
    <Location /bound>
        AuthType GSSAPI
        AuthName "dirnex-bound"
        GssapiCredStore keytab:/etc/apache2/http.keytab
        GssapiAllowedMech krb5
        GssapiConnectionBound On
        Require valid-user
    </Location>
</VirtualHost>
EOF
a2ensite -q dav >/dev/null
echo "negotiate stand-in: realm $REALM, KDC on 88/tcp, WebDAV on 80"
exec apache2ctl -D FOREGROUND
