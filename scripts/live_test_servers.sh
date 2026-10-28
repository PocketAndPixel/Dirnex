#!/bin/sh

# Stand up the throwaway SFTP and FTP servers the live test suites are gated on, and write the
# two config files they read (docs/NOTES.md ▸ Testing).
#
# Why this exists rather than a paragraph of instructions: the live suites are gated on a *file*,
# because `xcodebuild` forwards no shell environment to the test runner — and when that file is
# absent they do not fail, they **skip**, under a run summary that is byte-identical either way.
# Measured 2026-09-01 on this repo: `1018 tests in 169 suites passed` with the configs present and
# `1018 tests in 169 suites passed` with them gone, while the tests that actually executed went
# from **975 to 922** and the suites from 161 to 147. So fourteen suites and fifty-three tests can
# stop running with nothing anywhere saying so, which is how `sendsPartsConcurrently` shipped with
# its live suite never once having run against a server. NOTES said standing a server up was "ten
# minutes"; a check that lives in prose is not a check, so here it is as one command.
#
# This is a developer tool, never CI: CI has no server and those suites are *supposed* to skip
# there.
#
# Usage:
#   scripts/live_test_servers.sh up      # start all three, write /tmp/dirnex_{sftp,ftp,webdav}_live_test.json
#   scripts/live_test_servers.sh down    # stop them, remove the configs, unpin the host key
#
# The six S3 live suites are gated on /tmp/dirnex_s3_live_test.json, which this script cannot write
# — it needs a real account. `down` removes it and `status` reports it, so a live credential does not
# outlive the run that needed it.
#   scripts/live_test_servers.sh status  # what is running, and which suites it enables
#
# Requires `pyftpdlib` for the FTP half (`python3 -m pip install pyftpdlib`); the SFTP half needs
# only the system `sshd`, and Remote Login does **not** have to be switched on. The WebDAV half is
# macOS's own `/usr/sbin/httpd` with `mod_dav`, run unprivileged from a config written here, so it
# needs nothing installed either (PLAN.md §M32).
#
# **Nextcloud joins the WebDAV suite when Docker is running and its image is already here**, as the
# second server family PLAN.md §M32's risk row asks for: sabre/dav, which shares no code with
# Apache's `mod_dav`. This script never pulls the image (504 MB, `docker pull nextcloud:stable-apache`):
# that download is somebody's decision, and without it the Apache endpoints run as before. A fresh
# container per `up`, so its brute-force counter, which slows every request after a few wrong
# passwords, starts at zero; installing takes about half a minute.

set -eu

# **`/private/tmp`, not `${TMPDIR}`, and it is a fixture precondition rather than a preference.**
# That directory is itself gid 0, so a file created under it lands in `wheel` — which is what makes
# `RemoteAttributeWriteLiveTests`' downgrade fixture work: it chowns its file to gid 0 to reach a
# group the account is *not* in (the only way `sftp`'s silent set-gid drop is arrangeable), and from
# a group you already hold that chown is a permitted no-op. Under `${TMPDIR}` the parent is gid 20,
# the same chown is a real group change, and it fails `EPERM` — measured 2026-09-01, and it surfaces
# as **79 issues** claiming a mode write was not refused when it should have been, i.e. as a broken
# feature rather than as a misplaced fixture.
STATE="/private/tmp/dirnex-live-servers"
SFTP_PORT="${DIRNEX_SFTP_PORT:-2222}"
FTP_PORT="${DIRNEX_FTP_PORT:-2121}"
WEBDAV_PORT="${DIRNEX_WEBDAV_PORT:-8088}"
WEBDAVS_PORT="${DIRNEX_WEBDAVS_PORT:-8443}"
NEXTCLOUD_PORT="${DIRNEX_NEXTCLOUD_PORT:-8089}"
NEXTCLOUD_IMAGE=nextcloud:stable-apache
NEXTCLOUD_CONTAINER=dirnex-nextcloud
SFTP_CONFIG=/tmp/dirnex_sftp_live_test.json
FTP_CONFIG=/tmp/dirnex_ftp_live_test.json
WEBDAV_CONFIG=/tmp/dirnex_webdav_live_test.json
# Not written by this script and never can be: it holds a real cloud credential, which nothing here
# can mint. `status` reports whether it is there and `down` removes it, because unlike the two
# throwaway loopback passwords above it is a live secret sitting in /tmp.
S3_CONFIG=/tmp/dirnex_s3_live_test.json
KNOWN_HOSTS_KEY="[127.0.0.1]:${SFTP_PORT}"

start_sftp() {
    mkdir -p "$STATE/remote"
    [ -f "$STATE/host_ed25519" ] || ssh-keygen -t ed25519 -f "$STATE/host_ed25519" -N '' -q
    [ -f "$STATE/id_probe" ] || ssh-keygen -t ed25519 -f "$STATE/id_probe" -N '' -q
    cp "$STATE/id_probe.pub" "$STATE/authorized_keys"
    chmod 600 "$STATE/authorized_keys"

    # `MaxStartups`' **first** field is the lever, not the ceiling: six live suites run in parallel
    # and every VFS verb is a fresh `sftp` process (~250 logins for 24 tests), so a stock
    # `10:30:100` drops connections at random and it surfaces as `.io(code: 5)` naming a feature
    # that works. A bare `MaxStartups 500` sets only the ceiling and merely halves the failures.
    cat > "$STATE/sshd_config" <<EOF
Port $SFTP_PORT
ListenAddress 127.0.0.1
HostKey $STATE/host_ed25519
AuthorizedKeysFile $STATE/authorized_keys
PidFile $STATE/sshd.pid
LogLevel VERBOSE
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
Subsystem sftp /usr/libexec/sftp-server
MaxStartups 1000:30:2000
EOF

    # A stale pin from a *previous* throwaway on this port fails preauth, and the app's own error
    # then reads as a broken feature rather than as a stale `known_hosts` line.
    ssh-keygen -R "$KNOWN_HOSTS_KEY" >/dev/null 2>&1 || true
    # **On another clock than this Mac's, on purpose.** Anything the server formats itself — `ls`
    # over the exec channel — prints in the server's zone, and a server in this Mac's own zone hides
    # every bug where that time is read as ours: measured 2026-10-19, the search walk put a file
    # written at 16:41 at 09:41 against a server in New York, and agreed perfectly with one here.
    # `sshd` hands its `TZ` to every session. Kiritimati is UTC+14, which no other zone shares, so the
    # one Mac it would not move is the one at +14, and that one gets Pago Pago (UTC−11).
    if [ "$(date +%z)" = "+1400" ]; then sshd_tz=Pacific/Pago_Pago; else sshd_tz=Pacific/Kiritimati; fi
    TZ="$sshd_tz" /usr/sbin/sshd -f "$STATE/sshd_config" -E "$STATE/sshd.log"

    cat > "$SFTP_CONFIG" <<EOF
{
  "host": "127.0.0.1",
  "port": $SFTP_PORT,
  "user": "$(id -un)",
  "identityFile": "$STATE/id_probe",
  "remotePath": "$STATE/remote"
}
EOF
    echo "sftp  127.0.0.1:$SFTP_PORT  -> $STATE/remote  (server clock: $sshd_tz)"
}

start_ftp() {
    if ! python3 -c 'import pyftpdlib' >/dev/null 2>&1; then
        echo "ftp   SKIPPED: pyftpdlib is not installed (python3 -m pip install pyftpdlib)" >&2
        echo "      the two suites needing FTP stay dark: FTP live integration, Remote-to-remote relay" >&2
        return 0
    fi
    mkdir -p "$STATE/ftproot"
    cat > "$STATE/serve_ftp.py" <<'PY'
import logging, sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

root, log, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
logging.basicConfig(level=logging.INFO, filename=log, format="%(asctime)s %(message)s")
auth = DummyAuthorizer()
# `a` (APPE) is granted deliberately: it is FTP's create-if-absent, and withdrawing it is how the
# `STOR` fallback is reached on purpose — see FTPLiveIntegrationTests' own doc comment.
auth.add_user("probe", "probe-pw", root, perm="elradfmwMT")
handler = FTPHandler
handler.authorizer = auth
handler.passive_ports = range(60000, 60100)
server = FTPServer(("127.0.0.1", port), handler)
# The suites run in parallel; a low connection cap fails inside a shared helper and reads as a
# broken connect rather than as a server limit.
server.max_cons = 512
server.max_cons_per_ip = 512
server.serve_forever()
PY
    # Detached from this script's output, which it would otherwise hold open for as long as it
    # runs: `up | tail` then never ends. It logs to its own file.
    python3 "$STATE/serve_ftp.py" "$STATE/ftproot" "$STATE/ftpd.log" "$FTP_PORT" >/dev/null 2>&1 &
    echo $! > "$STATE/ftpd.pid"

    cat > "$FTP_CONFIG" <<EOF
{
  "host": "127.0.0.1",
  "port": $FTP_PORT,
  "user": "probe",
  "password": "probe-pw",
  "security": "plain",
  "remotePath": "/"
}
EOF
    echo "ftp   127.0.0.1:$FTP_PORT   -> $STATE/ftproot"
}

start_webdav() {
    dav="$STATE/dav"
    # A fresh tree every time: the suites mint their fixtures under UUID-named folders, but a lock a
    # killed run left in `DavLockDB` would answer 423 to the next one and read as a broken write.
    rm -rf "$dav"
    mkdir -p "$dav/data/basic" "$dav/data/digest" "$dav/data/public" "$dav/run" "$dav/lock" "$dav/logs"

    # A new self-signed certificate per `up`, so the pin the suite trusts is read from the config
    # and never from a constant someone copied. The `subjectAltName` is not needed by a pinned
    # connection (`--insecure` skips the name check) and is there so a plain `curl --cacert` probe
    # against the same server verifies.
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=127.0.0.1 \
        -addext subjectAltName=IP:127.0.0.1 \
        -keyout "$dav/tls.key" -out "$dav/tls.crt" >/dev/null 2>&1
    pin=$(openssl x509 -in "$dav/tls.crt" -pubkey -noout | openssl pkey -pubin -outform der \
        | openssl dgst -sha256 -binary | openssl base64)

    htpasswd -bc "$dav/basic.pw" probe probe-pw >/dev/null 2>&1
    # `htdigest` prompts for the password and has no batch flag; its line is
    # `user:realm:MD5(user:realm:password)`, which is all it would have written.
    printf 'probe:dirnex-digest:%s\n' "$(printf 'probe:dirnex-digest:probe-pw' | md5 -q)" > "$dav/digest.pw"

    # Three locations, one per way in: Basic, Digest (which macOS's Apache answers with Digest
    # alone, so the probe has to read the challenge to log in at all), and a public folder with no
    # account, which reads *and writes* anonymously. `DavDepthInfinity Off` is the NAS's setting,
    # so a listing that forgot its `Depth: 1` gets the 403 the NAS would give it.
    #
    # The access log carries the user and the status of every request, and one live test reads it:
    # how many logins a wrong password costs is the server's bookkeeping, not the client's opinion
    # (docs/LIVE-VERIFICATION.md ▸ count `Accepted publickey` in the server's own log).
    cat > "$dav/httpd.conf" <<EOF
ServerRoot "/usr"
ServerName 127.0.0.1
Listen 127.0.0.1:$WEBDAV_PORT
Listen 127.0.0.1:$WEBDAVS_PORT
LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule authn_core_module libexec/apache2/mod_authn_core.so
LoadModule authn_file_module libexec/apache2/mod_authn_file.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule authz_user_module libexec/apache2/mod_authz_user.so
LoadModule auth_basic_module libexec/apache2/mod_auth_basic.so
LoadModule auth_digest_module libexec/apache2/mod_auth_digest.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
LoadModule log_config_module libexec/apache2/mod_log_config.so
LoadModule mime_module libexec/apache2/mod_mime.so
LoadModule ssl_module libexec/apache2/mod_ssl.so
LoadModule socache_shmcb_module libexec/apache2/mod_socache_shmcb.so
Mutex file:$dav/run default
DefaultRuntimeDir "$dav/run"
PidFile "$dav/run/httpd.pid"
ErrorLog "$dav/logs/error.log"
LogFormat "%h %{remote}p %u \"%r\" %>s" dav
CustomLog "$dav/logs/access.log" dav
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5
DavLockDB "$dav/lock/DavLock"
DocumentRoot "$dav/data"
<Directory "$dav/data">
  Dav On
  DavDepthInfinity Off
  Require all granted
</Directory>
<Location "/basic">
  AuthType Basic
  AuthName "dirnex-basic"
  AuthUserFile "$dav/basic.pw"
  Require valid-user
</Location>
<Location "/digest">
  AuthType Digest
  AuthName "dirnex-digest"
  AuthDigestProvider file
  AuthUserFile "$dav/digest.pw"
  Require valid-user
</Location>
SSLSessionCache "shmcb:$dav/run/ssl_scache(512000)"
<VirtualHost 127.0.0.1:$WEBDAVS_PORT>
  SSLEngine on
  SSLCertificateFile "$dav/tls.crt"
  SSLCertificateKeyFile "$dav/tls.key"
</VirtualHost>
EOF
    if ! /usr/sbin/httpd -f "$dav/httpd.conf" -k start 2>"$dav/logs/start.log"; then
        echo "webdav SKIPPED: httpd did not start ($(head -1 "$dav/logs/start.log"))" >&2
        echo "      the Apache endpoints of the WebDAV live suite stay dark" >&2
        return 0
    fi

    # One entry per way in, and the suite runs every test once per entry. The facts each entry
    # states are claims about *that* endpoint, written down rather than inferred (docs/NOTES.md ▸
    # Live suites): which scheme the probe must settle on, whether its certificate is self-signed,
    # and whether a wrong password may be tried at all — never on the NAS, whose Account
    # Protection locks the account after a few.
    APACHE_ENDPOINTS=$(cat <<EOF
    {
      "name": "Apache, HTTP, Basic",
      "host": "127.0.0.1", "port": $WEBDAV_PORT, "tls": false, "root": "/basic",
      "user": "probe", "password": "probe-pw", "scheme": "basic",
      "remotePath": "/", "mayTryWrongPassword": true, "accessLog": "$dav/logs/access.log",
      "servedFrom": "$dav/data/basic"
    },
    {
      "name": "Apache, HTTP, Digest",
      "host": "127.0.0.1", "port": $WEBDAV_PORT, "tls": false, "root": "/digest",
      "user": "probe", "password": "probe-pw", "scheme": "digest",
      "remotePath": "/", "mayTryWrongPassword": true, "accessLog": "$dav/logs/access.log",
      "servedFrom": "$dav/data/digest"
    },
    {
      "name": "Apache, HTTP, public",
      "host": "127.0.0.1", "port": $WEBDAV_PORT, "tls": false, "root": "/public",
      "user": "", "remotePath": "/", "servedFrom": "$dav/data/public"
    },
    {
      "name": "Apache, HTTPS, Basic, pinned",
      "host": "127.0.0.1", "port": $WEBDAVS_PORT, "tls": true, "root": "/basic",
      "user": "probe", "password": "probe-pw", "scheme": "basic",
      "trustedPublicKey": "$pin", "selfSigned": true,
      "remotePath": "/", "mayTryWrongPassword": true, "accessLog": "$dav/logs/access.log",
      "servedFrom": "$dav/data/basic"
    }
EOF
)
    echo "webdav 127.0.0.1:$WEBDAV_PORT (http) and :$WEBDAVS_PORT (https, pinned) -> $dav/data"
}

start_nextcloud() {
    NEXTCLOUD_ENDPOINTS=""
    if ! docker info >/dev/null 2>&1; then
        echo "nextcloud SKIPPED: Docker is not running (the WebDAV suite's second server family stays dark)"
        return 0
    fi
    if ! docker image inspect "$NEXTCLOUD_IMAGE" >/dev/null 2>&1; then
        echo "nextcloud SKIPPED: no $NEXTCLOUD_IMAGE image here (docker pull $NEXTCLOUD_IMAGE, 504 MB)"
        return 0
    fi
    docker rm -f "$NEXTCLOUD_CONTAINER" >/dev/null 2>&1 || true
    # SQLite, so it is one container, and on loopback only. Nextcloud's password policy refuses a
    # short password, so the throwaway ones are longer than Apache's.
    docker run -d --name "$NEXTCLOUD_CONTAINER" -p "127.0.0.1:$NEXTCLOUD_PORT:80" \
        -e SQLITE_DATABASE=nextcloud -e NEXTCLOUD_ADMIN_USER=admin \
        -e NEXTCLOUD_ADMIN_PASSWORD=dirnex-admin-Nc-pw \
        -e NEXTCLOUD_TRUSTED_DOMAINS="127.0.0.1 localhost" "$NEXTCLOUD_IMAGE" >/dev/null
    installed=""
    for _ in $(seq 1 120); do
        if curl -q -s "http://127.0.0.1:$NEXTCLOUD_PORT/status.php" 2>/dev/null \
            | command grep -q '"installed":true'; then
            installed=yes
            break
        fi
        sleep 2
    done
    # No sample files in the account, so its root holds only what the suite makes.
    if [ -z "$installed" ] \
        || ! docker exec -u www-data "$NEXTCLOUD_CONTAINER" \
            php occ config:system:set skeletondirectory --value= >/dev/null 2>&1 \
        || ! docker exec -u www-data -e OC_PASS=dirnex-probe-Nc-pw "$NEXTCLOUD_CONTAINER" \
            php occ user:add --password-from-env probe >/dev/null 2>&1; then
        echo "nextcloud SKIPPED: the container did not install (docker logs $NEXTCLOUD_CONTAINER)" >&2
        return 0
    fi
    # **One request first, alone.** A new account's first login sets up its home, a calendar and
    # an address book, and the suite's parallel first requests raced over it: measured 2026-10-24,
    # four of thirteen tests failed their first MKCOL with 500 or 503, `"/probe" is locked` and
    # `UNIQUE constraint failed: oc_addressbooks…` in the server's log. A client connecting the
    # ordinary way asks one thing at a time and never meets it.
    printf 'user = "probe:dirnex-probe-Nc-pw"\n' | curl -q -s -o /dev/null --basic -K - -X PROPFIND \
        -H 'Depth: 0' "http://127.0.0.1:$NEXTCLOUD_PORT/remote.php/dav/files/probe/"
    version=$(curl -q -s "http://127.0.0.1:$NEXTCLOUD_PORT/status.php" \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["versionstring"])')
    # Its claims, each measured (PLAN.md §M32): names stored composed, a lock that guards only the
    # file itself, and `X-OC-Mtime` honoured. No access log or served folder: its Apache logs no
    # user, and its files live inside the container.
    NEXTCLOUD_ENDPOINTS=$(cat <<EOF
    {
      "name": "Nextcloud $version, HTTP, Basic",
      "host": "127.0.0.1", "port": $NEXTCLOUD_PORT, "tls": false,
      "root": "/remote.php/dav/files/probe",
      "user": "probe", "password": "dirnex-probe-Nc-pw", "scheme": "basic",
      "remotePath": "/", "mayTryWrongPassword": true,
      "composesNames": true, "lockGuardsFolder": false, "keepsUploadDates": true
    }
EOF
)
    echo "nextcloud 127.0.0.1:$NEXTCLOUD_PORT ($version, container $NEXTCLOUD_CONTAINER)"
}

# One file for every WebDAV endpoint that came up, so the suite runs each test once per server.
write_webdav_config() {
    endpoints=""
    for entry in "${APACHE_ENDPOINTS:-}" "${NEXTCLOUD_ENDPOINTS:-}"; do
        [ -z "$entry" ] && continue
        if [ -z "$endpoints" ]; then
            endpoints="$entry"
        else
            endpoints="$endpoints,
$entry"
        fi
    done
    if [ -z "$endpoints" ]; then
        echo "webdav: no endpoint came up, so $WEBDAV_CONFIG is not written and the suite stays dark" >&2
        return 0
    fi
    printf '{\n  "endpoints": [\n%s\n  ]\n}\n' "$endpoints" > "$WEBDAV_CONFIG"
}

case "${1:-up}" in
up)
    start_sftp
    start_ftp
    start_webdav
    start_nextcloud
    write_webdav_config
    sleep 1
    echo
    echo "Configs written. Now run the app suite and read the *per-suite* lines, not the"
    echo "summary count — the summary is identical whether these ran or not:"
    echo
    echo "  xcodebuild test -project Dirnex.xcodeproj -scheme Dirnex 2>&1 |"
    echo "    command grep -cE '✔ Test '      # 1811 with servers up, 1755 without (2026-10-24)"
    ;;
down)
    # By port rather than by pid file: a pid file is the one record that goes missing exactly when
    # it is needed (a moved state directory, a reboot, a crash), and a server left listening then
    # collides with the next `up` as `Address already in use` — which reads as a broken script.
    for port in "$SFTP_PORT" "$FTP_PORT" "$WEBDAV_PORT" "$WEBDAVS_PORT"; do
        pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)
        [ -n "$pids" ] && echo "$pids" | xargs kill 2>/dev/null || true
    done
    # By name, never by port: that port is Docker's own proxy, and killing it takes Docker down.
    if docker info >/dev/null 2>&1 && docker rm -f "$NEXTCLOUD_CONTAINER" >/dev/null 2>&1; then
        echo "removed the $NEXTCLOUD_CONTAINER container (the image stays)"
    fi
    rm -f "$SFTP_CONFIG" "$FTP_CONFIG" "$WEBDAV_CONFIG" "$STATE/sshd.pid" "$STATE/ftpd.pid"
    if [ -f "$S3_CONFIG" ]; then rm -f "$S3_CONFIG"; echo "removed $S3_CONFIG (it held a live credential)"; fi
    # Leave no pin behind for a port the next throwaway will reuse with a different host key.
    ssh-keygen -R "$KNOWN_HOSTS_KEY" >/dev/null 2>&1 || true
    echo "stopped; configs removed and $KNOWN_HOSTS_KEY unpinned"
    ;;
status)
    lsof -nP -iTCP:"$SFTP_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
        && echo "sftp  listening on $SFTP_PORT" || echo "sftp  not running"
    lsof -nP -iTCP:"$FTP_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
        && echo "ftp   listening on $FTP_PORT" || echo "ftp   not running"
    lsof -nP -iTCP:"$WEBDAV_PORT" -sTCP:LISTEN >/dev/null 2>&1 \
        && echo "webdav listening on $WEBDAV_PORT and $WEBDAVS_PORT" || echo "webdav not running"
    docker ps --filter "name=^$NEXTCLOUD_CONTAINER\$" --format '{{.Names}}' 2>/dev/null \
        | command grep -q . && echo "nextcloud running on $NEXTCLOUD_PORT" || echo "nextcloud not running"
    [ -f "$SFTP_CONFIG" ] && echo "config $SFTP_CONFIG present" || echo "config $SFTP_CONFIG ABSENT — SFTP suites will skip silently"
    [ -f "$FTP_CONFIG" ] && echo "config $FTP_CONFIG present" || echo "config $FTP_CONFIG ABSENT — FTP suites will skip silently"
    [ -f "$WEBDAV_CONFIG" ] && echo "config $WEBDAV_CONFIG present" || echo "config $WEBDAV_CONFIG ABSENT — the WebDAV suite will skip silently"
    [ -f "$S3_CONFIG" ] && echo "config $S3_CONFIG present (real credential)" || echo "config $S3_CONFIG absent — the six S3 suites will skip silently"
    ;;
*)
    echo "usage: $0 [up|down|status]" >&2
    exit 2
    ;;
esac
