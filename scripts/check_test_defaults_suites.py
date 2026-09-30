#!/usr/bin/env python3
"""Fail the build if a test names a `UserDefaults` suite with anything but a fixed string literal.

`removePersistentDomain(forName:)` empties a domain but leaves its plist in
`~/Library/Preferences`, so a suite named with a fresh UUID leaves a file behind on every run,
whether or not the test cleans up. By 2026-09-13 the app tests had left 19,046 such files on the
developer's Mac (docs/NOTES.md ▸ Testing). Nothing logs, both suites stay green and nothing in the
repo changes, so a check living in prose is not a check (docs/NOTES.md) and this runs in CI.

The allowed spellings are `ScratchDefaults.fresh()`, which gives a test one fixed-name domain
emptied as the test starts, and a plain literal such as `UserDefaults(suiteName: "Foo")`. A name
built at runtime is refused, including one held in a variable, because this check cannot tell a
fixed name from `"Foo.\\(UUID().uuidString)"` once it has left the call. The helpers that build
names from fixed parts are allowed below, each with its reason.

Usage: scripts/check_test_defaults_suites.py [root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

TEST_DIRECTORIES = ("DirnexTests", "DirnexCore/Tests")
ARGUMENT = re.compile(r"\bsuiteName:\s*(.*)$")

# Files allowed to pass a suite name that is not a literal, keyed by path with the reason. Each
# builds its names from fixed parts; the reason is what a reviewer checks when one is added.
ALLOWED: dict[str, str] = {
    "DirnexTests/ScratchDefaults.swift": "the helper itself: the name comes from #fileID and #function",
    "DirnexTests/TabStateScratch.swift": "a single `static let` literal, cleared once per test host",
}


def literal_problem(argument: str) -> str | None:
    """Why `argument` (the text after `suiteName:`) is not a fixed literal, or `None` if it is."""
    if argument.startswith('"""'):
        return "a multi-line string literal, which this check cannot read"
    if not argument.startswith('"'):
        return "not a string literal"
    i = 1
    while i < len(argument):
        if argument[i] == "\\":
            if argument[i + 1 : i + 2] == "(":
                return "an interpolated string"
            i += 2
            continue
        if argument[i] == '"':
            return None
        i += 1
    return "a string literal this check cannot find the end of"


def check(path: Path, root: Path) -> list[str]:
    relative = str(path.relative_to(root))
    if relative in ALLOWED:
        return []
    lines = path.read_text().splitlines()
    problems: list[str] = []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("//"):
            continue
        match = ARGUMENT.search(line)
        if not match:
            continue
        argument = match.group(1).strip()
        # `UserDefaults(\n    suiteName:\n    "Foo")` puts the argument on a later line.
        j = i + 1
        while not argument and j < len(lines):
            argument = lines[j].strip()
            j += 1
        reason = literal_problem(argument)
        if reason:
            problems.append(
                f"{relative}:{i + 1}: the suite name is {reason}. Use `ScratchDefaults.fresh()` or a "
                f"fixed literal, since a name that changes per run leaves a plist behind every run\n"
                f"    {line.strip()}"
            )
    return problems


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    sources = sorted(f for d in TEST_DIRECTORIES for f in (root / d).rglob("*.swift"))
    if not sources:
        print(f"error: no Swift sources under {', '.join(str(root / d) for d in TEST_DIRECTORIES)}",
              file=sys.stderr)
        return 2

    problems = [p for f in sources for p in check(f, root)]
    if problems:
        print("Test defaults suites named at runtime (see docs/NOTES.md, Testing):\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print(f"\n{len(problems)} problem(s).", file=sys.stderr)
        return 1

    sites = sum(
        1
        for f in sources
        if str(f.relative_to(root)) not in ALLOWED
        for line in f.read_text().splitlines()
        if not line.lstrip().startswith("//") and ARGUMENT.search(line)
    )
    fresh = sum(f.read_text().count("ScratchDefaults.fresh(") for f in sources)
    print(f"OK: {sites} literal suite name(s) and {fresh} ScratchDefaults.fresh() call(s); "
          f"none named at runtime.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
