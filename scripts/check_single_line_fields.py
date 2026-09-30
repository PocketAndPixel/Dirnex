#!/usr/bin/env python3
"""Fail the build if an editable text field is built without `keepToOneLine()`.

Every bare AppKit initializer — `NSTextField()`, `NSTextField(frame:)` and both
`NSSecureTextField` spellings — hands back a cell with `wraps = true, isScrollable = false`
(measured on macOS 26; only `NSTextField(string:)` and the `labelWithString:` family are
single-line by construction). A value longer than the field therefore wraps onto a **second line
the field is too short to show**: the visible line breaks at the last `-` or `.`, leaving a gap of
empty field, and the rest of the name is simply not on screen — the shape a user reported for the
⇧F4 Edit File sheet, which had it in eleven other dialogs at the same time.

`NSTextField.keepToOneLine(truncating:)` is the one spelling allowed here. It fails in the quiet
direction — nothing logs, both suites stay green, the field really does hold the whole value, and
any screenshot taken with a short name is perfect — so a check living in prose is not a check
(docs/NOTES.md) and this runs in CI.

Usage: scripts/check_single_line_fields.py [root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

CONSTRUCTION = re.compile(
    r"^\s*(?:(?:private |fileprivate |public |internal )?(?:static )?(?:let|var) )?"
    r"(\w+)(?:: NS(?:Secure)?TextField)? = NS(?:Secure)?TextField\("
)
# `labelWithString:` and `wrappingLabelWithString:` are not editable, and `string:` already ships
# the single-line configuration (measured). The argument can sit on the next line, so the exclusion
# is tested against the construction *and* its continuation rather than against one line.
EXEMPT_INITIALIZERS = ("labelWithString", "wrappingLabelWithString", "string:")
CONFIGURED = "keepToOneLine("
# A function that calls `keepToOneLine` on whatever it is handed configures its arguments — the
# shape `MultiRenameController.configure(_:placeholder:string:width:)` uses for seven fields. Its
# callers must not be reported, or the check pushes code away from having one funnel.
FUNNEL = re.compile(r"^\s*(?:@\w+\s+)?(?:private |fileprivate |public |internal )?(?:static )?func (\w+)\(")

# Fields that legitimately want AppKit's wrapping cell. Each needs a reason, because the default is
# wrong for everything a name or a path is typed into.
ALLOWED: set[tuple[str, int]] = set()


def configuring_funnels(lines: list[str]) -> set[str]:
    """Names of functions in this file whose body calls `keepToOneLine`."""
    funnels: set[str] = set()
    current: str | None = None
    depth = 0
    started = False
    for line in lines:
        if current is None:
            m = FUNNEL.match(line)
            if m:
                current, depth, started = m.group(1), 0, False
            else:
                continue
        if CONFIGURED in line and current is not None:
            funnels.add(current)
        depth += line.count("{") - line.count("}")
        started = started or "{" in line
        if started and depth <= 0:
            current = None
    return funnels


def check(path: Path, root: Path) -> list[str]:
    lines = path.read_text().splitlines()
    text = "\n".join(lines)
    problems: list[str] = []
    relative = str(path.relative_to(root))
    funnels = configuring_funnels(lines)

    for i, line in enumerate(lines):
        m = CONSTRUCTION.search(line)
        if not m:
            continue
        # The initializer's argument may be on the following line.
        head = " ".join(lines[i:i + 2])
        if any(exempt in head for exempt in EXEMPT_INITIALIZERS):
            continue
        if (relative, i + 1) in ALLOWED:
            continue
        name = m.group(1)
        if f"{name}.{CONFIGURED}" in text:
            continue
        # Handed to a funnel that configures it — `configure(nameField, …)`.
        if any(re.search(rf"\b{funnel}\(\s*{name}\b", text) for funnel in funnels):
            continue
        problems.append(
            f"{relative}:{i + 1}: `{name}` is built from a wrapping cell and never calls "
            f"`{name}.keepToOneLine()` — a value longer than the field hides its tail on a "
            f"second line\n      {line.strip()}"
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
        print("Text fields that wrap instead of scrolling (see docs/NOTES.md, AppKit):\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print(f"\n{len(problems)} problem(s).", file=sys.stderr)
        return 1

    fields = 0
    for f in sources:
        lines = f.read_text().splitlines()
        for i, line in enumerate(lines):
            if CONSTRUCTION.search(line) and not any(
                exempt in " ".join(lines[i:i + 2]) for exempt in EXEMPT_INITIALIZERS
            ):
                fields += 1
    print(f"OK: all {fields} editable text fields call keepToOneLine().")
    return 0


if __name__ == "__main__":
    sys.exit(main())
