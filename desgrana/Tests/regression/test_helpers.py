# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""Binary discovery, session generation, and the fixture / real-data case runners."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

from .test_model import PREFIX, ExpectedOutput, TestCase
from .selog import write_selog_bin
from .chunks import verify_bext, verify_ixml, verify_markers
from .wav import (
    extract_channel_bytes,
    extract_stereo_bytes,
    find_active_channels,
    find_data_chunk,
    read_data_bytes,
    read_wav_fmt,
    write_wav_from_source,
    write_wav_synthetic,
)


# ── Binary discovery ──────────────────────────────────────────────────────────

def find_binary(hint: "str | None", desgrana_dir: str) -> str:
    if hint:
        if not os.path.isfile(hint):
            sys.exit(f"Error: binary not found: {hint}")
        return hint
    candidates = [
        os.path.join(desgrana_dir, ".build", "release", "desgrana"),
        os.path.join(desgrana_dir, ".build", "debug",   "desgrana"),
        shutil.which("desgrana") or "",
    ]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    sys.exit(
        "Error: desgrana binary not found.\n"
        "Build it with  make build  (or  swift build -c release),\n"
        "then pass the path:  python3 Tests/test_split.py .build/release/desgrana"
    )


# ── Session generation ────────────────────────────────────────────────────────

def write_session(case: TestCase, session_dir: str, tests_dir: str,
                  fixed_ts: bool = False) -> None:
    """Write input files (WAV + SE_LOG.BIN + optional snap) to session_dir."""
    os.makedirs(session_dir, exist_ok=True)
    ref_path = os.path.join(session_dir, "00000001.wav")

    if case.channel_signals is not None:
        write_wav_synthetic(ref_path, case)
    else:
        assert case.source_wav_rel is not None
        source_path = os.path.join(tests_dir, case.source_wav_rel)
        fmt_tag, nc, sr, bps = read_wav_fmt(source_path)
        case.format_tag      = fmt_tag
        case.num_channels    = nc
        case.sample_rate     = sr
        case.bits_per_sample = bps
        write_wav_from_source(ref_path, source_path, case)

    ts = 0 if fixed_ts else None
    write_selog_bin(os.path.join(session_dir, "SE_LOG.BIN"),
                    case.num_channels, case.sample_rate, case.total_frames,
                    case.markers, ts=ts)

    if case.snap_data is not None:
        snap_path = os.path.join(session_dir, case.snap_filename)
        with open(snap_path, "w") as f:
            json.dump(case.snap_data, f, indent=2)
        print(f"  Generated: {case.snap_filename}")


def run_desgrana(binary: str, session_dir: str, output_dir: str,
                 extra_args: list) -> bool:
    """Run desgrana and return True on success."""
    cmd = [binary, session_dir, "--output", output_dir, "--prefix", PREFIX] + extra_args
    print(f"  $ {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout:
        for line in result.stdout.splitlines():
            print(f"    {line}")
    if result.returncode != 0:
        print(result.stderr)
        print(f"\nError: desgrana exited with code {result.returncode}")
        return False
    return True


# ── Fixture-based runner (synthetic cases) ────────────────────────────────────

def run_case_generate(case: TestCase, binary: str, fixtures_dir: str) -> None:
    """Generate session inputs and capture expected outputs for a synthetic case."""
    session_dir  = os.path.join(fixtures_dir, case.name, "session")
    expected_dir = os.path.join(fixtures_dir, case.name, "expected")

    print(f"\n{'=' * 60}")
    print(f"  {case.name}  [generate]")
    print(f"{'=' * 60}")

    print("\n-- Writing session files")
    write_session(case, session_dir, fixtures_dir, fixed_ts=True)

    print("\n-- Running desgrana -> expected/")
    if os.path.isdir(expected_dir):
        shutil.rmtree(expected_dir)
    os.makedirs(expected_dir)

    if not run_desgrana(binary, session_dir, expected_dir, case.desgrana_extra_args):
        sys.exit(1)

    written = sorted(os.listdir(expected_dir))
    print(f"\n  Expected output ({len(written)} file(s)):")
    for fname in written:
        size = os.path.getsize(os.path.join(expected_dir, fname))
        print(f"    {fname}  ({size // 1024} KB)")


def wav_data_chunk(path: str):
    """Return the raw bytes of the 'data' chunk from a WAV file, or None."""
    with open(path, "rb") as f:
        if f.read(4) != b"RIFF":
            return None
        f.read(4)  # RIFF chunk size
        if f.read(4) != b"WAVE":
            return None
        while True:
            hdr = f.read(8)
            if len(hdr) < 8:
                return None
            chunk_id = hdr[:4]
            chunk_size = int.from_bytes(hdr[4:8], "little")
            if chunk_id == b"data":
                return f.read(chunk_size)
            f.seek(chunk_size + (chunk_size & 1), 1)   # RIFF chunks are word-aligned


def compare_outputs(output_dir: str, expected_dir: str) -> int:
    """Compare all files in output_dir against expected_dir. Returns failure count."""
    if not os.path.isdir(expected_dir):
        print("  SKIP  expected/ not found -- run with --generate first")
        return 0

    expected_files = sorted(
        f for f in os.listdir(expected_dir) if not f.startswith(".")
    )
    output_set = set(
        f for f in os.listdir(output_dir) if not f.startswith(".")
    )

    failures = 0
    for fname in expected_files:
        exp_path = os.path.join(expected_dir, fname)
        out_path = os.path.join(output_dir, fname)

        if not os.path.isfile(out_path):
            print(f"  FAIL  {fname}  missing from output")
            failures += 1
            continue

        if fname.lower().endswith(".wav"):
            exp_samples = wav_data_chunk(exp_path)
            out_samples = wav_data_chunk(out_path)
            if exp_samples is None or out_samples is None:
                print(f"  FAIL  {fname}  could not parse WAV data chunk")
                failures += 1
            elif exp_samples == out_samples:
                print(f"  OK    {fname}  ({len(out_samples) // 1024} KB samples)")
            else:
                print(f"  FAIL  {fname}  sample data differs"
                      f"  ({len(out_samples)} bytes got, {len(exp_samples)} expected)")
                for i, (a, e) in enumerate(zip(out_samples, exp_samples)):
                    if a != e:
                        print(f"         first diff at sample byte {i}"
                              f"  (frame ~{i // 4}): got 0x{a:02x} expected 0x{e:02x}")
                        break
                else:
                    direction = "longer" if len(out_samples) > len(exp_samples) else "shorter"
                    print(f"         output is {direction} than expected")
                failures += 1
        else:
            exp_data = open(exp_path, "rb").read()
            out_data = open(out_path, "rb").read()

            if exp_data == out_data:
                print(f"  OK    {fname}  ({len(out_data) // 1024} KB)")
            else:
                print(f"  FAIL  {fname}  content differs"
                      f"  ({len(out_data)} bytes got, {len(exp_data)} expected)")
                for i, (a, e) in enumerate(zip(out_data, exp_data)):
                    if a != e:
                        print(f"         first diff at byte {i}"
                              f"  (frame ~{i // 4}): got 0x{a:02x} expected 0x{e:02x}")
                        break
                else:
                    direction = "longer" if len(out_data) > len(exp_data) else "shorter"
                    print(f"         output is {direction} than expected")
                failures += 1

    for fname in sorted(output_set - set(expected_files)):
        print(f"  FAIL  {fname}  in output but not in expected/ (unexpected file)")
        failures += 1

    return failures


def run_case_test(case: TestCase, binary: str, fixtures_dir: str, tmp_dir: str) -> int:
    """Test a synthetic case against committed fixtures. Returns failure count."""
    session_dir  = os.path.join(fixtures_dir, case.name, "session")
    expected_dir = os.path.join(fixtures_dir, case.name, "expected")
    output_dir   = os.path.join(tmp_dir, case.name, "out")

    print(f"\n{'=' * 60}")
    print(f"  {case.name}")
    print(f"{'=' * 60}")

    if not os.path.isdir(session_dir):
        print("  SKIP  fixtures not found -- run with --generate first")
        return 0

    if os.path.isdir(output_dir):
        shutil.rmtree(output_dir)
    os.makedirs(output_dir)

    print("\n-- Running desgrana")
    if not run_desgrana(binary, session_dir, output_dir, case.desgrana_extra_args):
        return 1

    print("\n-- Comparing output to expected/")
    failures = compare_outputs(output_dir, expected_dir)

    if case.expected_ixml:
        print("\n-- Verifying iXML track names")
        failures += verify_ixml(case, output_dir)

    print("\n-- Verifying bext chunk")
    failures += verify_bext(output_dir)

    if failures == 0:
        print("\n  OK  all checks passed")
    else:
        print(f"\n  {failures} check(s) failed")

    return failures


# ── Real-data runner (dynamic comparison, no committed fixtures) ──────────────

def run_case_real(case: TestCase, binary: str, var_dir: str, tests_dir: str) -> "tuple[int, int]":
    """Run a real-data case with dynamic comparison. Returns (audio_failures, marker_failures)."""
    case_dir    = os.path.join(var_dir, case.name)
    session_dir = os.path.join(case_dir, "session")
    output_dir  = os.path.join(case_dir, "out")
    ref_path    = os.path.join(session_dir, "00000001.wav")

    print(f"\n{'=' * 60}")
    print(f"  {case.name}")
    print(f"{'=' * 60}")

    print("\n-- Step 1: reference session")
    assert case.source_wav_rel is not None
    source_path = os.path.join(tests_dir, case.source_wav_rel)
    fmt_tag, nc, sr, bps = read_wav_fmt(source_path)
    case.format_tag      = fmt_tag
    case.num_channels    = nc
    case.sample_rate     = sr
    case.bits_per_sample = bps

    os.makedirs(session_dir, exist_ok=True)
    if os.path.isfile(ref_path):
        size_mb = os.path.getsize(ref_path) / (1024 * 1024)
        print(f"  Exists : {ref_path}  ({size_mb:.1f} MB, skipping)")
        _, data_size = find_data_chunk(ref_path)
        case.total_frames = data_size // (nc * (bps // 8))
    else:
        write_wav_from_source(ref_path, source_path, case)

    write_selog_bin(os.path.join(session_dir, "SE_LOG.BIN"),
                    case.num_channels, case.sample_rate, case.total_frames,
                    case.markers)

    print("\n-- Step 2: run desgrana")
    if os.path.isdir(output_dir):
        shutil.rmtree(output_dir)
    os.makedirs(output_dir)

    if not run_desgrana(binary, session_dir, output_dir, case.desgrana_extra_args):
        return 1, 0

    print("\n-- Step 3: byte-exact comparison")
    bps_bytes = case.bits_per_sample // 8
    ref_bytes = read_data_bytes(ref_path)

    expected = case.expected_outputs
    if expected is None:
        print("  Scanning input for active channels...")
        active   = find_active_channels(ref_bytes, case.num_channels, bps_bytes)
        expected = [ExpectedOutput(f"{PREFIX}ch{c + 1:02d}.wav", [c]) for c in active]
        print(f"  Active channels: {[c + 1 for c in active]}")

    audio_failures = 0
    for exp in expected:
        out_path = os.path.join(output_dir, exp.filename)
        if not os.path.isfile(out_path):
            print(f"  FAIL  {exp.filename}  not found")
            audio_failures += 1
            continue

        if len(exp.src_channels) == 1:
            want = extract_channel_bytes(ref_bytes, exp.src_channels[0], case.num_channels, bps_bytes)
        else:
            want = extract_stereo_bytes(ref_bytes, exp.src_channels[0], exp.src_channels[1],
                                        case.num_channels, bps_bytes)
        got = read_data_bytes(out_path)

        if got == want:
            size_kb = len(got) / 1024
            print(f"  OK    {exp.filename}  {size_kb:.0f} KB  ch={exp.src_channels}")
        else:
            print(f"  FAIL  {exp.filename}  mismatch ({len(got)} bytes got, {len(want)} expected)")
            for i, (a, e) in enumerate(zip(got, want)):
                if a != e:
                    print(f"         first diff: byte {i} (frame {i // bps_bytes}): "
                          f"got 0x{a:02x} expected 0x{e:02x}")
                    break
            audio_failures += 1

    expected_names = {e.filename for e in expected}
    for fname in sorted(f for f in os.listdir(output_dir) if f.lower().endswith(".wav")):
        if fname not in expected_names:
            print(f"  WARN  unexpected output file: {fname}")

    print("\n-- Step 4: marker verification")
    marker_failures = verify_markers(case, output_dir)

    total = audio_failures + marker_failures
    if total == 0:
        print("\n  OK  all checks passed")
    else:
        print(f"\n  {total} check(s) failed")

    return audio_failures, marker_failures
