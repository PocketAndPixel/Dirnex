"""An NTLM-authenticating reverse proxy that checks the real NTLMv2 proof, in front of a WebDAV server.

    python3 Tooling/fake-ntlm-proxy.py 8090 http://127.0.0.1:8088 /tmp/ntlm-access.log

It stands in for an IIS or Windows-domain WebDAV share (PLAN.md §M38, decided 2026-11-09): no real
IIS is involved, and nothing here should be read as one. What it does check is the cryptography. A
client's NTLMv2 response is verified exactly as a domain controller verifies it (MS-NLMP 3.3.2):
`NTOWFv2` from the account's password, user name and the domain the client sent, then the
`NTProofStr` over this connection's server challenge and the client's blob. A client that computes
the proof wrong, or with the wrong password, is refused, which a proxy that merely looked for an
`Authorization: NTLM` header would not do. The MS-NLMP 4.2.4 test vectors are checked at start-up,
so a broken MD4 or HMAC here fails loudly rather than refusing every login. NTLMv1 and NTLM2 session
responses (24 bytes) are refused, as a domain at `LmCompatibilityLevel` 5 refuses them.

The handshake is **per connection**, which is the whole reason NTLM differs from Basic and Digest:
the Type 2 challenge belongs to the TCP connection it was sent on, and once the Type 3 proof passes,
that connection is the user's until it closes (IIS's default, `authPersistNonNTLM`). So the state
lives on the handler, which `http.server` keeps for the life of a keep-alive connection.

Everything authenticated is forwarded unchanged to the upstream server, so the WebDAV semantics are
real ones (macOS's Apache `mod_dav`, from `scripts/live_test_servers.sh`) and only the sign-in is the
stand-in's. The upstream must serve the same paths anonymously; `Destination` and `Location` are
rewritten between the two addresses, since `mod_dav` refuses a `Destination` on another port.

Every request is one line in the access log, in the format `scripts/live_test_servers.sh` gives
Apache (`%h %{remote}p %u "%r" %>s`), so the WebDAV live suite counts failed logins here as it does
there: a 401 that carries a user is a refused proof, and a challenge is a 401 with none. The client's
port is its connection. `DETAIL_LOG` names a second file that gets one JSON line per request, with how
far its sign-in got (`none`, `type1`, `type3`, `session`) and why a proof was refused, which is what a
probe of `curl`'s behaviour reads (docs/LIVE-VERIFICATION.md: the server's bookkeeping, not the
client's opinion).

**One thing it does not reproduce:** the body of an authenticated request is read before the request
goes upstream, so a precondition Apache refuses (a 412) arrives after the whole body was sent. Apache
alone answers it before the body above 1 MiB (docs/NOTES.md ▸ curl (WebDAV)). Nothing in the live suite
counts uploaded bytes on a refusal.

Environment:
- `NTLM_USERS`: `user:password` pairs, comma-separated (default `probe:probe-pw`).
- `NTLM_DOMAIN`: the NetBIOS domain (default `DIRNEX`); its DNS name is `<domain>.test` lowercased.
  A client may send either, or none; any other domain is an account this server does not know.
- `OFFER`: the schemes a bare 401 offers, in order, one `WWW-Authenticate` header each (default
  `NTLM`; `Negotiate,NTLM` is IIS's shape). Only NTLM is ever accepted.
- `MAX_REQUESTS`: close a connection after this many requests, as Apache's `MaxKeepAliveRequests`
  does (default 0, never). A client then has to sign the next connection in again.
"""
import base64
import hmac
import json
import os
import socket
import struct
import sys
import threading
import time
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PORT = int(sys.argv[1])
UPSTREAM = urlsplit(sys.argv[2])
LOG = sys.argv[3]
DETAIL_LOG = os.environ.get("DETAIL_LOG")
DOMAIN = os.environ.get("NTLM_DOMAIN", "DIRNEX")
DNS_DOMAIN = DOMAIN.lower() + ".test"
USERS = dict(
    pair.split(":", 1) for pair in os.environ.get("NTLM_USERS", "probe:probe-pw").split(",") if pair
)
OFFER = [scheme.strip() for scheme in os.environ.get("OFFER", "NTLM").split(",") if scheme.strip()]
MAX_REQUESTS = int(os.environ.get("MAX_REQUESTS", "0"))
LOG_LOCK = threading.Lock()
CONNECTIONS = [0]


# MARK: - MD4 (RFC 1320), since OpenSSL 3 dropped it from hashlib's default provider


def md4(message: bytes) -> bytes:
    def rotate(value, bits):
        value &= 0xFFFFFFFF
        return ((value << bits) | (value >> (32 - bits))) & 0xFFFFFFFF

    length = (8 * len(message)) & 0xFFFFFFFFFFFFFFFF
    message += b"\x80" + b"\x00" * ((55 - len(message)) % 64) + struct.pack("<Q", length)
    a, b, c, d = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476
    for chunk in range(0, len(message), 64):
        x = struct.unpack("<16I", message[chunk:chunk + 64])
        aa, bb, cc, dd = a, b, c, d
        f = lambda x_, y, z: (x_ & y) | (~x_ & z)
        g = lambda x_, y, z: (x_ & y) | (x_ & z) | (y & z)
        h = lambda x_, y, z: x_ ^ y ^ z
        for i in range(16):
            k, s = i, (3, 7, 11, 19)[i % 4]
            if i % 4 == 0: a = rotate(a + f(b, c, d) + x[k], s)
            elif i % 4 == 1: d = rotate(d + f(a, b, c) + x[k], s)
            elif i % 4 == 2: c = rotate(c + f(d, a, b) + x[k], s)
            else: b = rotate(b + f(c, d, a) + x[k], s)
        for i in range(16):
            k, s = (i % 4) * 4 + i // 4, (3, 5, 9, 13)[i % 4]
            if i % 4 == 0: a = rotate(a + g(b, c, d) + x[k] + 0x5A827999, s)
            elif i % 4 == 1: d = rotate(d + g(a, b, c) + x[k] + 0x5A827999, s)
            elif i % 4 == 2: c = rotate(c + g(d, a, b) + x[k] + 0x5A827999, s)
            else: b = rotate(b + g(c, d, a) + x[k] + 0x5A827999, s)
        order = (0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15)
        for i in range(16):
            k, s = order[i], (3, 9, 11, 15)[i % 4]
            if i % 4 == 0: a = rotate(a + h(b, c, d) + x[k] + 0x6ED9EBA1, s)
            elif i % 4 == 1: d = rotate(d + h(a, b, c) + x[k] + 0x6ED9EBA1, s)
            elif i % 4 == 2: c = rotate(c + h(d, a, b) + x[k] + 0x6ED9EBA1, s)
            else: b = rotate(b + h(c, d, a) + x[k] + 0x6ED9EBA1, s)
        a, b, c, d = (a + aa) & 0xFFFFFFFF, (b + bb) & 0xFFFFFFFF, (c + cc) & 0xFFFFFFFF, (d + dd) & 0xFFFFFFFF
    return struct.pack("<4I", a, b, c, d)


# MARK: - NTLM (MS-NLMP)


def nt_owf_v2(password: str, user: str, domain: str) -> bytes:
    nt_hash = md4(password.encode("utf-16-le"))
    return hmac.new(nt_hash, (user.upper() + domain).encode("utf-16-le"), "md5").digest()


def nt_proof(password: str, user: str, domain: str, server_challenge: bytes, blob: bytes) -> bytes:
    return hmac.new(nt_owf_v2(password, user, domain), server_challenge + blob, "md5").digest()


def self_check():
    """MS-NLMP's own vectors, so a slip in MD4 or the HMAC chain cannot pass for a wrong password."""
    assert md4(b"").hex() == "31d6cfe0d16ae931b73c59d7e0c089c0"
    assert md4(b"abc").hex() == "a448017aaf21d8525fc10ae87aa6729d"
    assert md4("Password".encode("utf-16-le")).hex() == "a4f49c406510bdcab6824ee7c30fd852"  # 4.2.2.1.2
    assert nt_owf_v2("Password", "User", "Domain").hex() == "0c868a403bfd7a93a3001ef22ef02e3f"  # 4.2.4.1.1
    server_name = (struct.pack("<HH", 2, 12) + "Domain".encode("utf-16-le")
                   + struct.pack("<HH", 1, 12) + "Server".encode("utf-16-le") + struct.pack("<HH", 0, 0))
    temp = b"\x01\x01" + b"\x00" * 6 + b"\x00" * 8 + b"\xaa" * 8 + b"\x00" * 4 + server_name + b"\x00" * 4
    proof = nt_proof("Password", "User", "Domain", bytes.fromhex("0123456789abcdef"), temp)
    assert proof.hex() == "68cd0ab851e51c96aabc927bebef6a1c", proof.hex()  # 4.2.4.2.2


def av_pair(kind: int, value: bytes) -> bytes:
    return struct.pack("<HH", kind, len(value)) + value


def challenge_message(server_challenge: bytes) -> bytes:
    flags = (0x00000001 | 0x00000004 | 0x00000200 | 0x00008000 | 0x00010000
             | 0x00080000 | 0x00800000 | 0x20000000 | 0x80000000)
    target = DOMAIN.encode("utf-16-le")
    filetime = int((time.time() + 11644473600) * 10_000_000)
    info = (av_pair(2, DOMAIN.encode("utf-16-le")) + av_pair(1, b"S\x00T\x00A\x00N\x00D\x00I\x00N\x00")
            + av_pair(4, DNS_DOMAIN.encode("utf-16-le"))
            + av_pair(3, ("standin." + DNS_DOMAIN).encode("utf-16-le"))
            + av_pair(7, struct.pack("<Q", filetime)) + av_pair(0, b""))
    header = 48
    return (b"NTLMSSP\x00" + struct.pack("<I", 2)
            + struct.pack("<HHI", len(target), len(target), header)
            + struct.pack("<I", flags) + server_challenge + b"\x00" * 8
            + struct.pack("<HHI", len(info), len(info), header + len(target)) + target + info)


def field(message: bytes, at: int) -> bytes:
    length, _, offset = struct.unpack_from("<HHI", message, at)
    return message[offset:offset + length]


def verify_authenticate(message: bytes, server_challenge: bytes):
    """`(who, proved, why)`: the account the Type 3 message names, as `DOMAIN\\user` or `user`, and
    whether its proof holds.

    A user principal name (`user@dirnex.test`) arrives as the user with no domain, as Windows sends
    it, and is looked up by its part before the `@`. The proof is computed over the names exactly as
    sent, which is what a domain controller does (MS-NLMP 3.3.2)."""
    if not message.startswith(b"NTLMSSP\x00") or struct.unpack_from("<I", message, 8)[0] != 3:
        return None, False, "not a Type 3 message"
    flags = struct.unpack_from("<I", message, 60)[0]
    encoding = "utf-16-le" if flags & 1 else "latin-1"
    nt_response = field(message, 20)
    domain = field(message, 28).decode(encoding)
    user = field(message, 36).decode(encoding)
    who = f"{domain}\\{user}" if domain else user
    if len(nt_response) <= 24:
        return who, False, "NTLMv1 or NTLM2 session response refused"
    name, _, upn_domain = user.partition("@")
    domains = (DOMAIN.upper(), DNS_DOMAIN.upper())
    if (domain and domain.upper() not in domains) or (upn_domain and upn_domain.upper() not in domains):
        return who, False, "unknown domain"
    account = next((known for known in USERS if known.lower() == name.lower()), None)
    if account is None:
        return who, False, "unknown user"
    expected = nt_proof(USERS[account], user, domain, server_challenge, nt_response[16:])
    if not hmac.compare_digest(expected, nt_response[:16]):
        return who, False, "wrong NTLMv2 proof"
    return who, True, "ok"


# MARK: - The proxy


def note(handler, entry):
    """One access-log line in Apache's format, and the detail line when there is a detail log."""
    user = entry.get("user") or "-"
    line = (f'{handler.client_address[0]} {handler.client_address[1]} {user} '
            f'"{handler.command} {handler.path} {handler.request_version}" {entry["status"]}\n')
    entry["conn"] = handler.connection_number
    entry["method"] = handler.command
    entry["path"] = handler.path
    with LOG_LOCK:
        with open(LOG, "a") as handle:
            handle.write(line)
        if DETAIL_LOG:
            with open(DETAIL_LOG, "a") as handle:
                handle.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        with LOG_LOCK:
            CONNECTIONS[0] += 1
            self.connection_number = CONNECTIONS[0]
        self.server_challenge = None
        self.user = None
        self.upstream = None
        self.requests = 0

    def log_message(self, *args):
        pass

    def handle_expect_100(self):
        # Decided per request below: a proof is checked before the body is asked for, as IIS does.
        self.expects_continue = True
        return True

    def body(self):
        if getattr(self, "expects_continue", False):
            self.wfile.write(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.wfile.flush()
            self.expects_continue = False
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip(), 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        return self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def refuse(self, stage, challenges, why=None, user=None):
        """A 401. A body the client announced but was not asked for closes the connection, since
        it would otherwise be read as the next request."""
        waiting = getattr(self, "expects_continue", False)
        if not waiting:
            self.body()
        self.send_response(401)
        for value in challenges:
            self.send_header("WWW-Authenticate", value)
        self.send_header("Content-Length", "0")
        if waiting:
            self.send_header("Connection", "close")
            self.close_connection = True
            self.expects_continue = False
        self.end_headers()
        note(self, {"auth": stage, "user": user, "status": 401, "why": why,
                    "length": self.headers.get("Content-Length")})

    def dispatch(self):
        self.expects_continue = getattr(self, "expects_continue", False)
        if self.user is not None:
            return self.forward("session")
        header = self.headers.get("Authorization", "")
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "ntlm" or not token:
            return self.refuse("none", OFFER)
        try:
            message = base64.b64decode(token.strip())
        except ValueError:
            return self.refuse("none", OFFER, why="undecodable token")
        kind = struct.unpack_from("<I", message, 8)[0] if len(message) >= 12 else 0
        if kind == 1:
            self.server_challenge = os.urandom(8)
            challenge = base64.b64encode(challenge_message(self.server_challenge)).decode()
            return self.refuse("type1", [f"NTLM {challenge}"])
        if kind == 3 and self.server_challenge is not None:
            who, proved, why = verify_authenticate(message, self.server_challenge)
            self.server_challenge = None
            if not proved:
                return self.refuse("type3", OFFER, why=why, user=who)
            self.user = who
            return self.forward("type3")
        return self.refuse("none", OFFER, why="Type 3 with no challenge on this connection")

    def forward(self, stage):
        body = self.body()
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in ("authorization", "connection", "expect", "host",
                                          "transfer-encoding", "content-length", "keep-alive")}
        own = f"http://{self.headers.get('Host', '')}"
        upstream_base = f"{UPSTREAM.scheme}://{UPSTREAM.netloc}"
        if "Destination" in headers:
            headers["Destination"] = headers["Destination"].replace(own, upstream_base, 1)
        headers["Host"] = UPSTREAM.netloc
        headers["Content-Length"] = str(len(body))
        for attempt in range(2):
            try:
                if self.upstream is None:
                    self.upstream = HTTPConnection(UPSTREAM.hostname, UPSTREAM.port, timeout=300)
                self.upstream.request(self.command, self.path, body=body, headers=headers)
                response = self.upstream.getresponse()
                payload = response.read()
                break
            except (ConnectionError, OSError, Exception):
                self.upstream = None
                if attempt == 1:
                    raise
        self.send_response(response.status, response.reason)
        for key, value in response.getheaders():
            if key.lower() in ("transfer-encoding", "connection", "keep-alive", "content-length"):
                continue
            if key.lower() == "location":
                value = value.replace(upstream_base, own, 1)
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.requests += 1
        if MAX_REQUESTS and self.requests >= MAX_REQUESTS:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)
        note(self, {"auth": stage, "user": self.user, "status": response.status, "bodyIn": len(body)})

    do_GET = do_HEAD = do_PUT = do_DELETE = do_OPTIONS = do_POST = dispatch
    do_PROPFIND = do_PROPPATCH = do_MKCOL = do_MOVE = do_COPY = do_LOCK = do_UNLOCK = dispatch


if __name__ == "__main__":
    self_check()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print(f"ntlm stand-in on 127.0.0.1:{PORT} -> {UPSTREAM.geturl()} (domain {DOMAIN})", flush=True)
    server.serve_forever()
