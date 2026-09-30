"""A local Sparkle feed offering one update, dated whenever the test needs, that can never install.

    python3 Tooling/fake-update-feed.py 8766 2027-04-01 /tmp/feed.log

Point a build at it with `-SUFeedURL http://127.0.0.1:8766/appcast.xml` (a launch argument, so the
real preferences never gain it). It is how M29's notice for an update the license doesn't cover is
tried without releasing anything: the one item is Dirnex `VERSION` (default 1.4.0), build 999999 so
it outranks any real build, released on the given UTC day. A key whose last day is before it doesn't
cover it (docs/RELEASING.md ▸ Trying the update notice).

**Nothing it offers can install.** The enclosure points back here and is answered 404, and every
request for it is written to the log as `"download": true`. That line is the evidence the notice's
promise rests on: with a key the update doesn't cover, no check of any kind asks for the DMG. Its
absence proves something only next to a run that did ask, so try the same launch without a key first
(docs/RELEASING.md). The signature is a placeholder for the same reason: Sparkle checks it only after
a download, which never succeeds.

`CHANNEL=beta` tags the item for the beta channel. Untagged, every install sees it.
"""
import json
import os
import sys
import time
from datetime import date
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
DAY = date.fromisoformat(sys.argv[2])
LOG = sys.argv[3]
VERSION = os.environ.get("VERSION", "1.4.0")
CHANNEL = os.environ.get("CHANNEL", "")
# Midday UTC, so the item's day is the same in every time zone Sparkle might parse it in.
PUB_DATE = DAY.strftime("%a, %d %b %Y") + " 12:00:00 +0000"
CHANNEL_TAG = f"\n            <sparkle:channel>{CHANNEL}</sparkle:channel>" if CHANNEL else ""
APPCAST = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Dirnex</title>
        <link>https://github.com/olegasd123/Dirnex</link>
        <description>Dirnex app updates (local test feed, Tooling/fake-update-feed.py)</description>
        <language>en</language>
        <item>
            <title>Version {VERSION}</title>
            <link>https://github.com/olegasd123/Dirnex</link>{CHANNEL_TAG}
            <sparkle:version>999999</sparkle:version>
            <sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>{PUB_DATE}</pubDate>
            <enclosure url="http://127.0.0.1:{PORT}/Dirnex.dmg"
                       sparkle:edSignature="{"A" * 86}=="
                       length="4096"
                       type="application/octet-stream" />
        </item>
    </channel>
</rss>
""".encode()


def note(entry):
    with open(LOG, "a") as handle:
        handle.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._answer(send_body=True)

    def do_HEAD(self):
        self._answer(send_body=False)

    def _answer(self, send_body):
        is_feed = self.path.split("?")[0] == "/appcast.xml"
        note({
            "time": time.strftime("%H:%M:%S"),
            "method": self.command,
            "path": self.path,
            "download": not is_feed,
            "agent": self.headers.get("User-Agent", ""),
        })
        if not is_feed:
            print(f"DOWNLOAD REQUESTED: {self.command} {self.path}", file=sys.stderr, flush=True)
        body = APPCAST if is_feed else b""
        self.send_response(200 if is_feed else 404)
        self.send_header("Content-Type", "application/rss+xml" if is_feed else "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)


print(f"Feed: http://127.0.0.1:{PORT}/appcast.xml — Dirnex {VERSION}, released {DAY}", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
