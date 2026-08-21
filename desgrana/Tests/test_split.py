#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""
Regression tests for desgrana (suite entry point).

Usage
-----
  make test
  python3 desgrana/Tests/test_split.py [binary]

Runs desgrana against committed fixtures in Tests/fixtures/<case>/session/ and
compares every output file against Tests/fixtures/<case>/expected/
(WAV files: sample data only, ignoring container chunks; other files: byte-for-byte).


  python3 desgrana/Tests/test_split.py --generate [binary]

Writes deterministic input files to Tests/fixtures/<case>/session/ and runs
desgrana to produce Tests/fixtures/<case>/expected/.  Run once after cloning
or after any intentional change to desgrana's output format:

  python3 desgrana/Tests/test_split.py --generate var/shipit/desgrana
  git add desgrana/Tests/fixtures/
  git commit -m "Update test fixtures"

Adding a test case
------------------
Append a synthetic TestCase to CASES in regression/cases.py, then run --generate.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from regression.cases import CASES
from regression.cli import (
    run_cli_error_tests,
    run_cli_json_tests,
    run_cli_output_tests,
    run_fallback_tests,
    run_ixml_test,
)
from regression.private import PRIVATE_SUITES
from regression.test_helpers import (
    find_binary,
    run_case_generate,
    run_case_real,
    run_case_test,
)


def main() -> None:
    script_dir   = os.path.dirname(os.path.abspath(__file__))
    desgrana_dir = os.path.dirname(script_dir)
    beriwave_dir = os.path.dirname(desgrana_dir)
    tests_dir    = script_dir
    fixtures_dir = os.path.join(tests_dir, "fixtures")
    var_dir      = os.path.join(beriwave_dir, "var", "tmp", "tests")

    args = sys.argv[1:]
    generate_mode = "--generate" in args
    args = [a for a in args if a != "--generate"]

    # --only <name>[,<name>...] restricts the run to those cases. Mainly for
    # --generate, so adding one fixture does not rewrite the committed ones.
    only: "set[str] | None" = None
    if "--only" in args:
        idx = args.index("--only")
        if idx + 1 >= len(args):
            sys.exit("--only requires a comma-separated list of case names")
        only = set(args[idx + 1].split(","))
        del args[idx:idx + 2]

        unknown = only - {c.name for c in CASES}
        if unknown:
            sys.exit(f"unknown case name(s): {', '.join(sorted(unknown))}")

    cases = [c for c in CASES if only is None or c.name in only]

    binary = find_binary(args[0] if args else None, desgrana_dir)
    print(f"Binary : {binary}")
    if generate_mode:
        print(f"Mode   : generate  (writing to {fixtures_dir})")
    if only is not None:
        print(f"Cases  : {', '.join(sorted(only))}")
    print()

    if generate_mode:
        for case in cases:
            if case.source_wav_rel is not None:
                print(f"\n[SKIP] {case.name}  (real-data cases have no committed fixtures)")
                continue
            run_case_generate(case, binary, fixtures_dir)
        print(f"\n{'=' * 60}")
        print(f"Fixtures written. Commit with:")
        print(f"  git add desgrana/Tests/fixtures/")
        print(f"  git commit -m \"Update test fixtures\"")
        return

    total_failures = 0
    run_count = skip_count = 0

    total_failures += run_cli_error_tests(binary)
    total_failures += run_cli_output_tests(binary, fixtures_dir)
    total_failures += run_cli_json_tests(binary, fixtures_dir, var_dir)
    total_failures += run_fallback_tests(binary, var_dir)
    total_failures += run_ixml_test(binary, var_dir)

    for suite in PRIVATE_SUITES:
        total_failures += suite(binary)

    for case in cases:
        if case.source_wav_rel is not None:
            source_path = os.path.join(tests_dir, case.source_wav_rel)
            if not os.path.isfile(source_path):
                print(f"\n[SKIP] {case.name}  (source not found: {source_path})")
                skip_count += 1
                continue
            af, mf = run_case_real(case, binary, var_dir, tests_dir)
            total_failures += af + mf
        else:
            total_failures += run_case_test(case, binary, fixtures_dir, var_dir)
        run_count += 1

    print(f"\n{'=' * 60}")
    if total_failures == 0:
        print(f"All {run_count} case(s) passed."
              + (f"  {skip_count} skipped." if skip_count else ""))
    else:
        sys.exit(f"{total_failures} failure(s) across {run_count} case(s).")


if __name__ == "__main__":
    main()
