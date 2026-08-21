# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""CLI-level suites: error handling, --info/--dry-run, --json, WLive routing,
input fallbacks, and iXML naming. Each returns a failure count."""

from __future__ import annotations

import array as ar
import json
import os
import shutil
import struct
import subprocess
import tempfile

from .test_model import FREQS, SAMPLE_RATE, SignalSpec, TestCase
from .wav import _pack_chunk, make_channel_samples, write_wav_synthetic


# ── CLI error handling tests ──────────────────────────────────────────────────

def run_cli_error_tests(binary: str) -> int:
    """Test CLI error exit codes and stderr messages. Returns failure count."""
    print(f"\n{'=' * 60}")
    print("  CLI error handling")
    print(f"{'=' * 60}\n")

    failures = 0

    def check(label: str, args: list, expected_exit: int, stderr_contains: str = "") -> None:
        nonlocal failures
        result = subprocess.run([binary] + args, capture_output=True, text=True)
        ok_exit = result.returncode == expected_exit
        ok_msg  = stderr_contains.lower() in result.stderr.lower() if stderr_contains else True
        if ok_exit and ok_msg:
            print(f"  OK    {label}")
        else:
            print(f"  FAIL  {label}")
            if not ok_exit:
                print(f"         exit: got {result.returncode}, expected {expected_exit}")
            if not ok_msg:
                print(f"         stderr missing {stderr_contains!r}")
                print(f"         stderr: {result.stderr.strip()!r}")
            failures += 1

    with tempfile.TemporaryDirectory() as tmp:
        check("empty dir -> exit 2",            [tmp],                            2, "No WAV take files")
        check("unknown option -> exit 1",        [tmp, "--bad-flag"],              1, "Unknown option")
        check("bad stereo pair -> exit 1",       [tmp, "--stereo", "abc"],         1, "invalid pair")
        check("--stereo missing value -> exit 1",[tmp, "--stereo"],                1, "requires a value")
        check("--output missing value -> exit 1",[tmp, "--output"],                1, "requires a path")
        check("--prefix missing value -> exit 1",[tmp, "--prefix"],                1, "requires a value")
        check("--snap missing value -> exit 1",  [tmp, "--snap"],                  1, "requires a path")

    check("missing path -> exit 1",
          ["/nonexistent_desgrana_xyz_12345"], 1, "Not found")

    return failures


# ── CLI output spot-checks (--help, --info, --dry-run) ───────────────────────

def run_cli_output_tests(binary: str, fixtures_dir: str) -> int:
    """Spot-check human-readable output for --help, --info, --dry-run."""
    print(f"\n{'=' * 60}")
    print("  CLI output: --help, --info, --dry-run")
    print(f"{'=' * 60}\n")

    session_dir = os.path.join(fixtures_dir, "case01_stereo", "session")
    if not os.path.isdir(session_dir):
        print("  SKIP  case01_stereo fixtures not found -- run --generate first")
        return 0

    failures = 0

    def check(label: str, args: list, expected_exit: int,
              stdout_has: "list[str]" = (), stdout_missing: "list[str]" = ()) -> None:
        nonlocal failures
        result = subprocess.run([binary] + args, capture_output=True, text=True)
        ok = True
        if result.returncode != expected_exit:
            print(f"  FAIL  {label}  exit {result.returncode} (expected {expected_exit})")
            ok = False
        for phrase in stdout_has:
            if phrase not in result.stdout:
                print(f"  FAIL  {label}  stdout missing {phrase!r}")
                if ok:
                    print(f"         stdout: {result.stdout[:200]!r}")
                ok = False
        for phrase in stdout_missing:
            if phrase in result.stdout:
                print(f"  FAIL  {label}  stdout unexpectedly contains {phrase!r}")
                ok = False
        if ok:
            print(f"  OK    {label}")
        else:
            failures += 1

    check("--help",
          ["--help"], 0,
          stdout_has=["USAGE:", "EXIT CODES:", "--stereo", "--dry-run", "--info"])

    # --info: SE_LOG.BIN present -> shows channels, sample rate, takes
    check("--info (with SE_LOG.BIN)",
          [session_dir, "--info"], 0,
          stdout_has=["Channels", "2", "48000", "1/1", "complete"])

    # --dry-run all-mono: both channels listed individually
    check("--dry-run (all mono)",
          [session_dir, "--dry-run", "--prefix", "test_"], 0,
          stdout_has=["Dry run", "test_ch01.wav", "test_ch02.wav"],
          stdout_missing=["test_ch01-02.wav"])

    # --dry-run with stereo pair: one combined file, no individual files
    check("--dry-run (stereo 1:2)",
          [session_dir, "--dry-run", "--stereo", "1:2", "--prefix", "test_"], 0,
          stdout_has=["Dry run", "test_ch01-02.wav"],
          stdout_missing=["test_ch01.wav", "test_ch02.wav"])

    # --info without SE_LOG.BIN: fallback to listing WAV files
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(os.path.join(session_dir, "00000001.wav"),
                    os.path.join(tmp, "00000001.wav"))
        check("--info (no SE_LOG.BIN)",
              [tmp, "--info"], 0,
              stdout_has=["No SE_LOG.bin found", "00000001.wav"])

    return failures


# ── JSON report tests (--json) ────────────────────────────────────────────────

def run_cli_json_tests(binary: str, fixtures_dir: str, var_dir: str) -> int:
    """Validate the --json report: pure-JSON stdout, schema, provenance, outputs."""
    print(f"\n{'=' * 60}")
    print("  CLI output: --json report")
    print(f"{'=' * 60}\n")

    snap_session = os.path.join(fixtures_dir, "case05_snap", "session")
    usb_session  = os.path.join(fixtures_dir, "case08_usb_stereo", "session")
    silent_session = os.path.join(fixtures_dir, "case06_silent", "session")
    if not os.path.isdir(snap_session):
        print("  SKIP  fixtures not found -- run --generate first")
        return 0

    failures = 0

    def parse_json(label: str, args: list) -> "dict | None":
        nonlocal failures
        result = subprocess.run([binary] + args, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"  FAIL  {label}  exit {result.returncode}: {result.stderr.strip()!r}")
            failures += 1
            return None
        try:
            return json.loads(result.stdout)   # stdout must be pure JSON
        except json.JSONDecodeError as e:
            print(f"  FAIL  {label}  stdout is not valid JSON: {e}")
            print(f"         stdout: {result.stdout[:200]!r}")
            failures += 1
            return None

    def expect(label: str, cond: bool, detail: str = "") -> None:
        nonlocal failures
        if cond:
            print(f"  OK    {label}")
        else:
            print(f"  FAIL  {label}  {detail}")
            failures += 1

    # 1. Dry-run report: planned outputs, snap provenance, no outputs section.
    d = parse_json("--dry-run --json (snap)",
                   [snap_session, "--dry-run", "--json", "--short-names", "--prefix", "test_"])
    if d is not None:
        expect("schema == 1 and dryRun", d.get("schema") == 1 and d.get("dryRun") is True)
        expect("has plannedOutputs, no outputs",
               "plannedOutputs" in d and d.get("outputs") is None)
        pairs = d["decisions"]["stereoPairs"]
        expect("pair 3:4 from name",
               any(p["left"] == 3 and p["right"] == 4 and p["origin"] == "name" for p in pairs),
               str(pairs))
        names = {n["channel"]: n["source"] for n in d["decisions"]["channelNames"]}
        expect("channel names sourced from snap", names.get(1) == "snap" and names.get(3) == "snap")
        expect("format read in dry-run", d["input"]["format"]["channels"] == 4)
        expect("markers listed", d["markers"]["count"] == 3)

    # 2. Real extraction report: outputs, kept counts, sidecars.
    out = os.path.join(var_dir, "json_snap_out")
    if os.path.isdir(out):
        shutil.rmtree(out)
    d = parse_json("--json (snap, real)",
                   [snap_session, "-o", out, "--json", "--short-names", "--prefix", "test_"])
    if d is not None:
        expect("dryRun false, outputs present", d.get("dryRun") is False and "outputs" in d)
        expect("kept 2 mono + 1 stereo",
               d["outputs"]["keptMono"] == 2 and d["outputs"]["keptStereo"] == 1)
        expect("marker sidecars recorded",
               all(d["markers"]["sidecars"].get(k) for k in ("csv", "txt", "mid")))

    # 3. Hardware-routing provenance.
    if os.path.isdir(usb_session):
        d = parse_json("--dry-run --json (usb)", [usb_session, "--dry-run", "--json"])
        if d is not None:
            origins = {p["origin"] for p in d["decisions"]["stereoPairs"]}
            expect("hardware pairs tagged 'hardware'", origins == {"hardware"}, str(origins))

    # 4. Silent channel appears in ignored.silentTracks.
    if os.path.isdir(silent_session):
        out2 = os.path.join(var_dir, "json_silent_out")
        if os.path.isdir(out2):
            shutil.rmtree(out2)
        d = parse_json("--json (silent)", [silent_session, "-o", out2, "--json"])
        if d is not None:
            silent = d["ignored"]["silentTracks"]
            expect("channel 3 reported as silent",
                   any(t["channels"] == [3] for t in silent), str(silent))

    if failures == 0:
        print("\n  OK  all checks passed")
    else:
        print(f"\n  {failures} check(s) failed")
    return failures


# ── Fallback input tests (non-hex WAV, single file, ambiguous folder) ─────────

def run_fallback_tests(binary: str, var_dir: str) -> int:
    """Test the 'other recorders' fallback: a non-hex WAV in a folder, a single WAV
    file passed directly, and refusal of a folder with several non-hex WAVs."""
    print(f"\n{'=' * 60}")
    print("  Fallback input (non-hex WAV / single file / ambiguous)")
    print(f"{'=' * 60}\n")

    failures = 0
    base = os.path.join(var_dir, "fallback")
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)

    # A small 2-channel WAV, both channels with signal (neither silent).
    case = TestCase(
        name="fallback",
        num_channels=2,
        sample_rate=SAMPLE_RATE,
        total_frames=SAMPLE_RATE // 2,
        channel_signals=[SignalSpec(FREQS[0], 0), SignalSpec(FREQS[1], 0)],
    )

    def run(args: list) -> subprocess.CompletedProcess:
        return subprocess.run([binary] + args, capture_output=True, text=True)

    # 1. Directory with a single non-hex WAV, no SE_LOG.bin -> extracts.
    d1 = os.path.join(base, "dir_single")
    os.makedirs(d1)
    write_wav_synthetic(os.path.join(d1, "myshow.wav"), case)
    out1 = os.path.join(base, "out1")
    r = run([d1, "--output", out1, "--short-names"])
    produced = set(os.listdir(out1)) if os.path.isdir(out1) else set()
    if r.returncode == 0 and {"ch01.wav", "ch02.wav"} <= produced:
        print("  OK    folder with single non-hex WAV -> ch01.wav, ch02.wav")
    else:
        print(f"  FAIL  folder with single non-hex WAV (rc={r.returncode}, files={sorted(produced)})")
        print(f"         stderr: {r.stderr.strip()!r}")
        failures += 1

    # 2. A single WAV file passed directly -> extracts.
    out2 = os.path.join(base, "out2")
    r = run([os.path.join(d1, "myshow.wav"), "--output", out2, "--short-names"])
    produced = set(os.listdir(out2)) if os.path.isdir(out2) else set()
    if r.returncode == 0 and {"ch01.wav", "ch02.wav"} <= produced:
        print("  OK    single WAV file argument -> ch01.wav, ch02.wav")
    else:
        print(f"  FAIL  single WAV file argument (rc={r.returncode}, files={sorted(produced)})")
        print(f"         stderr: {r.stderr.strip()!r}")
        failures += 1

    # 3. Folder with several non-hex WAVs -> refused (exit 2, clear message).
    d3 = os.path.join(base, "dir_multi")
    os.makedirs(d3)
    write_wav_synthetic(os.path.join(d3, "first_song.wav"), case)
    write_wav_synthetic(os.path.join(d3, "second_song.wav"), case)
    r = run([d3, "--output", os.path.join(base, "out3")])
    if r.returncode == 2 and "multiple wav" in r.stderr.lower():
        print("  OK    folder with several non-hex WAVs -> refused (exit 2)")
    else:
        print(f"  FAIL  ambiguous folder not refused (rc={r.returncode})")
        print(f"         stderr: {r.stderr.strip()!r}")
        failures += 1

    if failures == 0:
        print("\n  OK  all checks passed")
    else:
        print(f"\n  {failures} check(s) failed")
    return failures


# ── iXML track names (field recorders) ───────────────────────────────────────

def run_ixml_test(binary: str, var_dir: str) -> int:
    """A WAV carrying an iXML chunk should have its tracks named from <TRACK_LIST>."""
    print(f"\n{'=' * 60}")
    print("  iXML track names")
    print(f"{'=' * 60}\n")

    base = os.path.join(var_dir, "ixml")
    if os.path.isdir(base):
        shutil.rmtree(base)
    os.makedirs(base)

    nc, sr, nf = 2, SAMPLE_RATE, SAMPLE_RATE // 2
    chans = [make_channel_samples(SignalSpec(FREQS[0], 0), nf, sr),
             make_channel_samples(SignalSpec(FREQS[1], 0), nf, sr)]
    pcm = ar.array("f", (chans[c][f] for f in range(nf) for c in range(nc))).tobytes()

    block_align = nc * 4
    fmt = struct.pack("<HHIIHH", 3, nc, sr, sr * block_align, block_align, 32) + struct.pack("<H", 0)
    ixml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<BWFXML><TRACK_LIST><TRACK_COUNT>2</TRACK_COUNT>"
        "<TRACK><CHANNEL_INDEX>1</CHANNEL_INDEX><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>Boom</NAME></TRACK>"
        "<TRACK><CHANNEL_INDEX>2</CHANNEL_INDEX><INTERLEAVE_INDEX>2</INTERLEAVE_INDEX><NAME>Lav</NAME></TRACK>"
        "</TRACK_LIST></BWFXML>"
    ).encode("utf-8")
    if len(ixml) % 2:
        ixml += b"\n"  # keep RIFF chunks even-aligned

    riff = b"WAVE" + _pack_chunk(b"fmt ", fmt) + _pack_chunk(b"iXML", ixml) + _pack_chunk(b"data", pcm)
    path = os.path.join(base, "field.wav")
    with open(path, "wb") as f:
        f.write(_pack_chunk(b"RIFF", riff))

    out = os.path.join(base, "out")
    r = subprocess.run([binary, path, "--output", out, "--short-names"], capture_output=True, text=True)
    produced = set(os.listdir(out)) if os.path.isdir(out) else set()

    if r.returncode == 0 and {"Boom.wav", "Lav.wav"} <= produced:
        print("  OK    iXML names applied -> Boom.wav, Lav.wav")
        return 0
    print(f"  FAIL  iXML names not applied (rc={r.returncode}, files={sorted(produced)})")
    print(f"         stderr: {r.stderr.strip()!r}")
    return 1
