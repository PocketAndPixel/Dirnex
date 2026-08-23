"""A minimal S3-shaped endpoint that writes down every request it is asked to serve.

    python3 Tooling/fake-s3-endpoint.py 9444 /tmp/requests.log

It is **not** a mock of S3's semantics and must never be read as one — it does not verify a
signature, so it will agree with a broken client (docs/NOTES.md ▸ curl for S3: "a mock is not a
server"). What it is for is the half a real account cannot show cheaply: *the wire*. Which requests
the app makes, in what order, and what it puts in `x-amz-copy-source` — which is how the cross-bucket
server-side copy was verified without an AWS account, including that an incompatible pair makes no
copy request at all and that a refused one is followed by a GET and a PUT.

Path-style addressing, so a bucket is the first URL segment and two buckets share one process; two
processes on two ports are two *services*, which is the distinction the copy route turns on. Set
`REFUSE_COPY=1` to answer every server-side copy with the refusal S3 gives a source over 5 GiB,
which is the branch that has no other way to be reached.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

PORT = int(sys.argv[1])
LOG = sys.argv[2]
REFUSE_COPY = os.environ.get("REFUSE_COPY") == "1"
OBJECTS = {}  # "bucket/key" -> bytes


def note(entry):
    with open(LOG, "a") as handle:
        handle.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _target(self):
        return unquote(self.path.lstrip("/").split("?")[0])

    def _send(self, status, body=b"", extra=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        target = self._target()
        note({"method": "GET", "target": target})
        body = OBJECTS.get(target)
        if body is None:
            self._send(404, b"<Error><Code>NoSuchKey</Code></Error>")
        else:
            self._send(200, body)

    def do_HEAD(self):
        target = self._target()
        note({"method": "HEAD", "target": target})
        body = OBJECTS.get(target)
        self._send(200 if body is not None else 404, b"")

    def do_PUT(self):
        target = self._target()
        source = self.headers.get("x-amz-copy-source")
        if source:
            note({"method": "COPY", "target": target, "copySource": source})
            if REFUSE_COPY:
                self._send(
                    400,
                    b"<Error><Code>InvalidRequest</Code><Message>The specified copy source is "
                    b"larger than the maximum allowable size for a copy source: 5368709120"
                    b"</Message></Error>",
                )
                return
            origin = unquote(source.lstrip("/"))
            body = OBJECTS.get(origin)
            if body is None:
                self._send(404, b"<Error><Code>NoSuchKey</Code></Error>")
                return
            OBJECTS[target] = body
            self._send(200, b"<CopyObjectResult><ETag>\"deadbeef\"</ETag></CopyObjectResult>")
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        note({"method": "PUT", "target": target, "bytes": len(body)})
        OBJECTS[target] = body
        self._send(200, b"", {"ETag": '"deadbeef"'})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
