#!/usr/bin/env python3
"""Fail the build if any `NSAlert` reaches the screen without `enableEscapeToCancel()`.

`NSAlert` binds Escape itself by matching the **byte string "Cancel"** against a button's title,
so under any translation the binding silently stops happening — probed directly: a button titled
«Отмена» is given no key equivalent at all, while the English "Cancel" gets `\\u{1b}` in every
language. A sheet without a Cancel button (one lone "OK") has no Escape in *any* language.

`NSAlert.enableEscapeToCancel(safe:)` assigns Escape by **position**, which is why it is the one
spelling allowed here. It exists, it is documented in docs/NOTES.md, and 21 alerts still shipped
without it — the New Folder sheet among them, Escape-dead in all thirteen non-English languages.
Nothing logs, every test stays green, and the English screenshot is perfect: a check living in
prose is not a check (docs/NOTES.md), so this runs in CI.

**The call is not the binding**, which is the 2026-08-20 lesson: this script reported "all 70
NSAlert sites call enableEscapeToCancel()" while three of them — the download, iCloud and search
progress sheets — had no Escape at all, because the helper was a no-op for a single-button alert
that carried an accessory. Checking that a fix is *invoked* says nothing about whether it *took*,
so the binding itself is now pinned by `EscapeToDismissTests.everyShapeAnswersBothKeys`, which
asserts Escape and Return together on every shape the app builds. What is left here is the half a
test cannot see — that every alert reaches the helper at all, and reaches it with all of its
buttons already added, since the helper chooses by position and a button added afterwards silently
moves the safe one.

Usage: scripts/check_alert_escape.py [root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

CONSTRUCTION = re.compile(r"^(\s*)let (\w+) = NSAlert\(\)\s*$")
# Anything that puts the alert on screen. `runAlert`/`runTagAlert` are the app's own async
# wrappers; a new one must be named here or its alerts go unchecked.
RUNNERS = ("runModal", "beginSheetModal", "runAlert", "runTagAlert")

# Alerts that legitimately never reach a user's screen. Keep this empty if at all possible; a
# alert nobody can see is usually a sign the code is dead rather than a reason to skip the check.
ALLOWED: set[tuple[str, int]] = set()


def check(path: Path, root: Path) -> list[str]:
    text = path.read_text()
    lines = text.splitlines()
    problems: list[str] = []

    # The scan below keys on one exact spelling, so anything else is a hole rather than a pass.
    for i, line in enumerate(lines, 1):
        if "NSAlert(" in line and not CONSTRUCTION.match(line):
            problems.append(
                f"{path.relative_to(root)}:{i}: NSAlert built in a form this check cannot read "
                f"— rewrite as `let alert = NSAlert()` or teach the check its shape\n    {line.strip()}"
            )

    for i, line in enumerate(lines):
        m = CONSTRUCTION.match(line)
        if not m:
            continue
        if (str(path.relative_to(root)), i + 1) in ALLOWED:
            continue
        name = m.group(2)
        enabled = False
        enabled_at = None
        last_button_at = None
        for j in range(i + 1, len(lines)):
            body = lines[j]
            if f"{name}.enableEscapeToCancel(" in body:
                enabled = True
                enabled_at = j + 1
            if f"{name}.addButton(" in body:
                last_button_at = j + 1
            # Stop at the first thing that shows the alert: the call has to come before it, and
            # an alert shown twice would only need the first one covered anyway.
            if any(f"{name}" in body and r in body for r in RUNNERS):
                break
            if CONSTRUCTION.match(body):  # a second alert in the same function
                break
        if not enabled:
            problems.append(
                f"{path.relative_to(root)}:{i + 1}: `{name}` is shown without "
                f"`{name}.enableEscapeToCancel()` — Escape will not dismiss it once translated"
            )
        elif last_button_at is not None and enabled_at is not None and enabled_at < last_button_at:
            # The helper picks the safe button by position, so a button added after it runs shifts
            # the choice underneath it — silently, and only in the alert's last-added language.
            problems.append(
                f"{path.relative_to(root)}:{i + 1}: `{name}.enableEscapeToCancel()` at line "
                f"{enabled_at} runs before `addButton` at line {last_button_at} — it binds by "
                f"position, so call it once every button is added"
            )
    return problems


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    sources = sorted((root / "Dirnex").rglob("*.swift"))
    if not sources:
        print(f"error: no Swift sources under {root / 'Dirnex'}", file=sys.stderr)
        return 2

    problems = [p for f in sources for p in check(f, root)]
    if problems:
        print("Alerts missing Escape-to-dismiss (see docs/NOTES.md, Localization):\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print(f"\n{len(problems)} problem(s).", file=sys.stderr)
        return 1

    alerts = sum(1 for f in sources for line in f.read_text().splitlines() if CONSTRUCTION.match(line))
    print(f"OK: all {alerts} NSAlert sites call enableEscapeToCancel().")
    return 0


if __name__ == "__main__":
    sys.exit(main())
