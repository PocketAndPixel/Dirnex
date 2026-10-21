#!/usr/bin/env python3
"""Compare two `defaults export` files, including JSON stored inside plist data or strings.

JSONEncoder may change object key order on every save. Compare decoded content, while keeping
array order and plist value types. Print key names only: defaults may contain private paths.

Usage: python3 scripts/check_defaults_unchanged.py before.plist after.plist
"""

from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path


def content(value: object, *, decode_json: bool = True) -> object:
    if decode_json and isinstance(value, (bytes, str)):
        try:
            decoded = json.loads(value)
        except (ValueError, UnicodeDecodeError):
            pass
        else:
            return type(value), content(decoded, decode_json=False)
    if isinstance(value, dict):
        return {key: content(item, decode_json=decode_json) for key, item in value.items()}
    if isinstance(value, list):
        return [content(item, decode_json=decode_json) for item in value]
    return type(value), value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()
    before = plistlib.loads(args.before.read_bytes())
    after = plistlib.loads(args.after.read_bytes())
    changed = [
        key for key in sorted(before.keys() | after.keys())
        if key not in before or key not in after or content(before[key]) != content(after[key])
    ]
    if changed:
        print(f"FAIL: {len(changed)} defaults key(s) changed:")
        for key in changed:
            print(f"  {key}")
        return 1
    print(f"OK: all {len(before)} defaults keys are unchanged by content.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
