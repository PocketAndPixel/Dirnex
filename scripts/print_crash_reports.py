#!/usr/bin/env python3
"""Print why each macOS crash report says its process crashed, and the crashing thread's frames.

When the app test host crashes in CI, `xcodebuild` restarts it and the log says only "Test crashed
with signal segv." against whichever test was running — on 2026-10-02 one that passes on its own
and in a full local run. macOS writes a report (`Dirnex-<date>.ips`) to the runner's
`~/Library/Logs/DiagnosticReports`, and CI copies it out and runs this, so the stack is in the log
rather than only in a downloaded artifact.

A report is a JSON header line followed by the JSON body; the body's `threads` carry `triggered`
on the one that crashed, and each frame points into `usedImages`.

Usage: scripts/print_crash_reports.py report.ips [report.ips ...]
"""

from __future__ import annotations

import json
import sys

MAX_FRAMES = 30


def describe(path: str) -> list[str]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        _header, _, body = handle.read().partition("\n")
    report = json.loads(body)
    images = report.get("usedImages", [])
    exception = report.get("exception", {})
    termination = report.get("termination", {})
    lines = [
        f"{path}: {exception.get('type', '?')} {exception.get('signal', '')}"
        f" {termination.get('indicator', '')}".rstrip()
    ]
    for thread in report.get("threads", []):
        if not thread.get("triggered"):
            continue
        lines.append(f"  crashed thread: {thread.get('queue') or thread.get('name') or '(unnamed)'}")
        for frame in thread.get("frames", [])[:MAX_FRAMES]:
            index = frame.get("imageIndex", -1)
            image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
            symbol = frame.get("symbol") or hex(frame.get("imageOffset", 0))
            source = frame.get("sourceFile")
            where = f"  {source}:{frame.get('sourceLine')}" if source else ""
            lines.append(f"    {image}  {symbol}{where}")
    return lines


def main(paths: list[str]) -> int:
    for path in paths:
        try:
            print("\n".join(describe(path)))
        except (OSError, ValueError) as error:
            print(f"{path}: could not read the report ({error})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
