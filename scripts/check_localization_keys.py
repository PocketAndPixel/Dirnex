#!/usr/bin/env python3
"""Fail when a string the compiler extracted is missing from the string catalog.

The half of the localization design that nothing else can see. A `String(localized:)` or a
SwiftUI literal is keyed by its **English text**, and a key the catalog never received
compiles to itself — so the string renders in English inside a fully translated build, with
no error, no log line, and a perfect English screenshot. `LocalizationCoverageTests` reads
the compiled bundle and can only check the keys it knows to ask for (the symbolic registry
ones, plus the handful of `allCases` enums); this reads what the *compiler* extracted, which
is every key there is.

Run it after a build — the data is the `.stringsdata` Xcode emits per source file:

    xcodebuild build -project Dirnex.xcodeproj -scheme Dirnex -destination 'platform=macOS'
    python3 scripts/check_localization_keys.py

Pass `--derived-data <path>` when the build used `-derivedDataPath`; otherwise the newest
`~/Library/Developer/Xcode/DerivedData/Dirnex-*` is used.
"""

import argparse
import json
import pathlib
import plistlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# Which catalog serves which extraction table. An App Shortcut *phrase* is written to its own
# table and compiles from its own catalog — a phrase left in `Localizable.xcstrings` is
# silently English (docs/NOTES.md ▸ Localization).
CATALOGS = {
    "Localizable": REPO / "Dirnex/Localizable.xcstrings",
    "AppShortcuts": REPO / "Dirnex/AppShortcuts.xcstrings",
}

# Keys that are correctly absent, each with the reason it can never be translated.
ALLOWED = {
    # `ColorPicker("", …)`/`Picker("", …)` under `.labelsHidden()` — there is no label.
    "": "an empty label on a control whose label is hidden",
    # `DisplayRepresentation(title: "\(name)")`, where `name` already came out of
    # `LocalizedCatalog`. The *format* is all the compiler sees, and it is only punctuation.
    "%@": "a format whose every argument is already localized",
}


def stringsdata(derived_data: pathlib.Path) -> dict[tuple[str, str], list[str]]:
    """Every (table, key) the compiler extracted, mapped to the files that produced it."""
    roots = [
        derived_data / "Build/Intermediates.noindex/Dirnex.build",
        derived_data / "Build/Intermediates.noindex/DirnexCore.build",
    ]
    found: dict[tuple[str, str], list[str]] = {}
    for root in roots:
        for path in root.rglob("*.stringsdata"):
            raw = path.read_bytes()
            try:
                data = plistlib.loads(raw)
            except plistlib.InvalidFileException:
                data = json.loads(subprocess.run(
                    ["plutil", "-convert", "json", "-o", "-", str(path)],
                    capture_output=True, check=True,
                ).stdout)
            source = pathlib.Path(data.get("source", path.name)).name
            for table, entries in (data.get("tables") or {}).items():
                for entry in entries:
                    line = (entry.get("location") or {}).get("startingLine")
                    site = f"{source}:{line}" if line else source
                    found.setdefault((table, entry["key"]), []).append(site)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=pathlib.Path)
    args = parser.parse_args()

    derived = args.derived_data
    if derived is None:
        builds = sorted(
            (pathlib.Path.home() / "Library/Developer/Xcode/DerivedData").glob("Dirnex-*"),
            key=lambda p: p.stat().st_mtime,
        )
        if not builds:
            print("no Dirnex build in DerivedData — build the app scheme first", file=sys.stderr)
            return 2
        derived = builds[-1]

    extracted = stringsdata(derived)
    if not extracted:
        print(f"no .stringsdata under {derived} — build the app scheme first", file=sys.stderr)
        return 2

    catalogs = {
        table: set(json.loads(path.read_text())["strings"])
        for table, path in CATALOGS.items()
    }

    missing = []
    for (table, key), sites in sorted(extracted.items()):
        if key in ALLOWED:
            continue
        known = catalogs.get(table)
        if known is None:
            missing.append((table, key, sites, f"no catalog is wired to the “{table}” table"))
        elif key not in known:
            missing.append((table, key, sites, None))

    if missing:
        print(f"{len(missing)} extracted string(s) missing from the catalog:\n", file=sys.stderr)
        for table, key, sites, note in missing:
            print(f"  [{table}] {key!r}", file=sys.stderr)
            print(f"      {'; '.join(sites)}" + (f"  ({note})" if note else ""), file=sys.stderr)
        print(
            "\nEach renders in English inside every translated build. Add it to "
            f"{CATALOGS['Localizable'].relative_to(REPO)} (or to the table's own catalog), "
            "or list it in ALLOWED here with the reason it cannot be translated.",
            file=sys.stderr,
        )
        return 1

    print(f"{len(extracted)} extracted keys, all present in the catalogs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
