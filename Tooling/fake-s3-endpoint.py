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

It speaks enough **multipart** to run a real upload — create, part, complete, abort — and logs each
part's start and end, which is how the parallel upload was shown to be parallel: four parts opening
at the same instant rather than one after another. `DELAY=<seconds>` holds every response open, so
overlap is visible on a machine fast enough to hide it otherwise.

It serves **`Range`** for the same reason in the other direction: a segmented download is N range
requests in one `curl`, and each is logged with its own start and end. `IGNORE_RANGE=1` answers them
with the whole object under a 200 instead — a success that is not what was asked for, which is the
branch the backend has to notice and route around, and which no well-behaved server will produce on
demand.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

PORT = int(sys.argv[1])
LOG = sys.argv[2]
REFUSE_COPY = os.environ.get("REFUSE_COPY") == "1"
# Answer a `Range` request with the whole object under a 200 — the S3-compatible endpoint that does
# not honour ranges, which is the one branch a segmented download has to notice and route around.
IGNORE_RANGE = os.environ.get("IGNORE_RANGE") == "1"
DELAY = float(os.environ.get("DELAY", "0"))
# Hold each part open for DELAY x its number, so parts in one batch finish at different times —
# which is what makes per-part progress reporting visible rather than merely believed.
STAGGER = os.environ.get("STAGGER") == "1"
OBJECTS = {}  # "bucket/key" -> bytes
UPLOADS = {}  # upload id -> {part number: bytes}


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
        started = time.time()
        target = self._target()
        body = OBJECTS.get(target)
        if body is None:
            note({"method": "GET", "target": target})
            self._send(404, b"<Error><Code>NoSuchKey</Code></Error>")
            return
        # A `Range` request is what a segmented download is made of, so it is served properly —
        # 206 with the piece and a `Content-Range` — and logged with its start and end, which is
        # how "several at once" is told from "one after another".
        span = self._range(len(body))
        if span is None:
            note({"method": "GET", "target": target, "bytes": len(body)})
            if DELAY:
                time.sleep(DELAY)
            self._send(200, body)
            return
        first, last = span
        if IGNORE_RANGE:
            note({"method": "GET", "target": target, "range": "ignored"})
            self._send(200, body)
            return
        if first >= len(body):
            self._send(416, b"<Error><Code>InvalidRange</Code></Error>")
            return
        piece = body[first:last + 1]
        if DELAY:
            time.sleep(DELAY)
        note({"method": "RANGE", "target": target, "first": first, "last": last,
              "bytes": len(piece), "start": round(started, 3), "end": round(time.time(), 3)})
        self._send(206, piece, {
            "Content-Range": "bytes %d-%d/%d" % (first, last, len(body)),
        })

    def _range(self, total):
        """`bytes=<first>-<last>` as a pair, or None when the request asked for the whole thing."""
        header = self.headers.get("Range")
        if not header or not header.startswith("bytes="):
            return None
        first, _, last = header[len("bytes="):].partition("-")
        try:
            first = int(first)
        except ValueError:
            return None
        return (first, int(last) if last else total - 1)

    def do_HEAD(self):
        target = self._target()
        note({"method": "HEAD", "target": target})
        body = OBJECTS.get(target)
        self._send(200 if body is not None else 404, b"")

    def _query(self, name):
        if "?" not in self.path:
            return None
        for pair in self.path.split("?", 1)[1].split("&"):
            key, _, value = pair.partition("=")
            if key == name:
                return unquote(value)
        return None

    def do_POST(self):
        target = self._target()
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        upload = self._query("uploadId")
        if upload is None:  # ?uploads — open one
            upload = "upload-%d" % (len(UPLOADS) + 1)
            UPLOADS[upload] = {}
            note({"method": "CREATE", "target": target, "uploadId": upload})
            self._send(200, ("<InitiateMultipartUploadResult><UploadId>%s</UploadId>"
                             "</InitiateMultipartUploadResult>" % upload).encode())
            return
        parts = UPLOADS.pop(upload, {})
        note({"method": "COMPLETE", "target": target, "uploadId": upload,
              "parts": len(parts), "bytes": sum(len(v) for v in parts.values())})
        OBJECTS[target] = b"".join(parts[n] for n in sorted(parts))
        self._send(200, b"<CompleteMultipartUploadResult><ETag>\"whole\"</ETag>"
                        b"</CompleteMultipartUploadResult>")

    def do_DELETE(self):
        upload = self._query("uploadId")
        note({"method": "ABORT", "target": self._target(), "uploadId": upload})
        UPLOADS.pop(upload, None)
        self._send(204)

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
        started = time.time()
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        upload, number = self._query("uploadId"), self._query("partNumber")
        if DELAY:
            time.sleep(DELAY * (int(number) if STAGGER and number else 1))
        if upload and number:
            UPLOADS.setdefault(upload, {})[int(number)] = body
            note({"method": "PART", "part": int(number), "bytes": len(body),
                  "start": round(started, 3), "end": round(time.time(), 3)})
            self._send(200, b"", {"ETag": '"etag-part-%s"' % number})
            return
        note({"method": "PUT", "target": target, "bytes": len(body)})
        OBJECTS[target] = body
        self._send(200, b"", {"ETag": '"deadbeef"'})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
