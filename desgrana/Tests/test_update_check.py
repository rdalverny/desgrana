#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""
Smoke-test for the version update endpoint.
Requires network access — not part of the default test suite.
Run via: make test-update-check

Tests:
  1. Endpoint is reachable and returns valid JSON with required fields.
  2. Numeric version comparison (mirrors Swift String.compare(.numeric)):
     - old version    → update available
     - current version → no update
     - future version  → no update
"""
import sys
import json
import urllib.request

URL = "https://romaindalverny.com/atelier/desgrana/version.json"


def is_newer(a: str, b: str) -> bool:
    """Return True if version a > b (numeric component comparison)."""
    pa = [int(x) for x in a.split(".")]
    pb = [int(x) for x in b.split(".")]
    return pa > pb


def main() -> int:
    # 1. Fetch
    print(f"Fetching {URL} ...")
    try:
        with urllib.request.urlopen(URL, timeout=10) as resp:
            data = json.load(resp)
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    # 2. Shape
    for field in ("version", "url"):
        if field not in data:
            print(f"FAIL: missing '{field}' in response: {data}")
            return 1

    latest = data["version"]
    print(f"Latest version: {latest}")
    print()

    # 3. Comparison cases
    cases = [
        ("1.0.0",   True,  f"{latest} > 1.0.0  → update available"),
        (latest,    False, f"{latest} == {latest}  → no update"),
        ("99.0.0",  False, f"{latest} < 99.0.0  → no update"),
    ]

    failed = False
    for current, want, description in cases:
        got = is_newer(latest, current)
        ok = got == want
        tag = "OK  " if ok else "FAIL"
        print(f"  {tag}  {description}")
        if not ok:
            failed = True

    print()
    if failed:
        print("FAIL: one or more comparison cases failed")
        return 1

    print(f"OK: endpoint live, comparison logic correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
