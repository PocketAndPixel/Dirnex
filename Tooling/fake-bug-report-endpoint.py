"""A stand-in for the store's bug-report endpoint, for a live run of Report a Bug… (PLAN.md §M30).

    python3 Tooling/fake-bug-report-endpoint.py 9555 /tmp/bug-reports
    open -n <Debug build>/Dirnex.app --args -DirnexDebugBugReportURL http://127.0.0.1:9555/api/bug-reports

It is **not** the server and must never be read as one: the contract and its checks live in the
private repo (`web/src/bug-reports/contract.ts`), and this accepts anything that is a JSON object
with a description. What it is for is the wire, which the app's tests cannot see because they answer
through a `URLProtocol` stub inside the process: the headers that actually leave the Mac (whether the
system added a `User-Agent` or an `Accept-Language` of its own), and the body's exact bytes, to hold
against what *Show What Will Be Sent…* showed.

Each request is written to `<dir>/request-<n>.json` (method, path, headers) and its body, unchanged,
to `<dir>/body-<n>.json`.

- `STATUS=<code>` answers every request with that status instead of 201: `429` for the rate limit,
  `400` for a refusal (`{"error": "malformed"}`), `500` for a server problem.
- `DELAY=<seconds>` holds every answer open, for Cancel during a send and for the app's timeout.
- To try the network being down, stop this process: the port then refuses the connection.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
DIRECTORY = sys.argv[2]
STATUS = int(os.environ.get("STATUS", "201"))
DELAY = float(os.environ.get("DELAY", "0"))
COUNT = 0

os.makedirs(DIRECTORY, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _answer(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if status == 429:
            self.send_header("Retry-After", "3600")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global COUNT
        COUNT += 1
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with open(os.path.join(DIRECTORY, f"request-{COUNT}.json"), "w") as handle:
            json.dump(
                {"method": "POST", "path": self.path, "headers": dict(self.headers.items())},
                handle,
                indent=2,
            )
        with open(os.path.join(DIRECTORY, f"body-{COUNT}.json"), "wb") as handle:
            handle.write(body)
        print(f"#{COUNT} {self.path} {length} bytes", flush=True)

        if DELAY:
            time.sleep(DELAY)
        if self.path != "/api/bug-reports":
            self._answer(404, {"error": "notFound"})
            return
        if STATUS != 201:
            reason = {400: "malformed", 413: "tooLarge", 429: "rateLimited"}.get(STATUS, "serverProblem")
            self._answer(STATUS, {"error": reason})
            return
        try:
            report = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            self._answer(400, {"error": "malformed"})
            return
        if not isinstance(report, dict) or report.get("v") != 1:
            self._answer(400, {"error": "malformed"})
            return
        if not str(report.get("description", "")).strip():
            self._answer(400, {"error": "missingDescription"})
            return
        self._answer(201, {"id": f"FAKE-{COUNT}"})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
