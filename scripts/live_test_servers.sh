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
#   scripts/live_test_servers.sh up      # start both, write /tmp/dirnex_{sftp,ftp}_live_test.json
#   scripts/live_test_servers.sh down    # stop both, remove the configs, unpin the host key
#
# The six S3 live suites are gated on /tmp/dirnex_s3_live_test.json, which this script cannot write
# — it needs a real account. `down` removes it and `status` reports it, so a live credential does not
# outlive the run that needed it.
#   scripts/live_test_servers.sh status  # what is running, and which suites it enables
#
# Requires `pyftpdlib` for the FTP half (`python3 -m pip install pyftpdlib`); the SFTP half needs
# only the system `sshd`, and Remote Login does **not** have to be switched on.

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
SFTP_CONFIG=/tmp/dirnex_sftp_live_test.json
FTP_CONFIG=/tmp/dirnex_ftp_live_test.json
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
    /usr/sbin/sshd -f "$STATE/sshd_config" -E "$STATE/sshd.log"

    cat > "$SFTP_CONFIG" <<EOF
{
  "host": "127.0.0.1",
  "port": $SFTP_PORT,
  "user": "$(id -un)",
  "identityFile": "$STATE/id_probe",
  "remotePath": "$STATE/remote"
}
EOF
    echo "sftp  127.0.0.1:$SFTP_PORT  -> $STATE/remote"
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
    python3 "$STATE/serve_ftp.py" "$STATE/ftproot" "$STATE/ftpd.log" "$FTP_PORT" &
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

case "${1:-up}" in
up)
    start_sftp
    start_ftp
    sleep 1
    echo
    echo "Both configs written. Now run the app suite and read the *per-suite* lines, not the"
    echo "summary count — the summary is identical whether these ran or not:"
    echo
    echo "  xcodebuild test -project Dirnex.xcodeproj -scheme Dirnex 2>&1 |"
    echo "    command grep -cE '^✔ Test '     # 975 with servers up, 922 without"
    ;;
down)
    # By port rather than by pid file: a pid file is the one record that goes missing exactly when
    # it is needed (a moved state directory, a reboot, a crash), and a server left listening then
    # collides with the next `up` as `Address already in use` — which reads as a broken script.
    for port in "$SFTP_PORT" "$FTP_PORT"; do
        pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)
        [ -n "$pids" ] && echo "$pids" | xargs kill 2>/dev/null || true
    done
    rm -f "$SFTP_CONFIG" "$FTP_CONFIG" "$STATE/sshd.pid" "$STATE/ftpd.pid"
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
    [ -f "$SFTP_CONFIG" ] && echo "config $SFTP_CONFIG present" || echo "config $SFTP_CONFIG ABSENT — SFTP suites will skip silently"
    [ -f "$FTP_CONFIG" ] && echo "config $FTP_CONFIG present" || echo "config $FTP_CONFIG ABSENT — FTP suites will skip silently"
    [ -f "$S3_CONFIG" ] && echo "config $S3_CONFIG present (real credential)" || echo "config $S3_CONFIG absent — the six S3 suites will skip silently"
    ;;
*)
    echo "usage: $0 [up|down|status]" >&2
    exit 2
    ;;
esac
