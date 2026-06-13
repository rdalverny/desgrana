#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""
test_split.py -- Regression tests for desgrana.

Usage
-----
  make test                                        # build CLI then run tests
  python3 desgrana/Tests/test_split.py [binary]   # test mode (default)
  python3 desgrana/Tests/test_split.py --generate [binary]  # regenerate fixtures

Test mode
---------
Runs desgrana against committed fixtures in Tests/fixtures/<case>/session/ and
compares every output file against Tests/fixtures/<case>/expected/
(WAV files: sample data only, ignoring container chunks; other files: byte-for-byte).

Generate mode
-------------
Writes deterministic input files to Tests/fixtures/<case>/session/ and runs
desgrana to produce Tests/fixtures/<case>/expected/.  Run once after cloning
or after any intentional change to desgrana's output format:

  python3 desgrana/Tests/test_split.py --generate var/shipit/desgrana
  git add desgrana/Tests/fixtures/
  git commit -m "Update test fixtures"

Test cases
----------
  case01_stereo  2-ch WAV, --stereo 1:2      -> 1 stereo output + markers
  case02_4mono   4-ch WAV, all mono          -> 4 mono outputs + markers
  case03_mixed   4-ch WAV, --stereo 3:4      -> 2 mono + 1 stereo + markers
  case05_snap    4-ch WAV + .snap file       -> stereo pair + 2 mono (from snap) + markers
  case04_real    32-ch WAV from SD Card      -> dynamic, skipped when source absent

Adding a synthetic test case
----------------------------
Append a TestCase to CASES with channel_signals set, then run --generate:

    TestCase(
        name="case06_foo",
        num_channels=2,
        sample_rate=48_000,
        total_frames=48_000 * 2,
        channel_signals=[
            SignalSpec(freq_hz=440.0, offset_frames=0),
            SignalSpec(freq_hz=880.0, offset_frames=12_000),  # 0.25 s silent prefix
        ],
        desgrana_extra_args=["--stereo", "1:2"],
        markers=[24_000],
    )

Adding a real-data test case
----------------------------
    TestCase(
        name="case06_real",
        source_wav_rel="SD Card/00000001.WAV",
        truncate_frames=48_000 * 10,
        fadeout_frames=48_000,
        desgrana_extra_args=[],
        markers=[],
        expected_outputs=None,  # None = auto-detect active channels
    )
"""

from __future__ import annotations

import array as ar
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field

# ── Constants ─────────────────────────────────────────────────────────────────

SAMPLE_RATE   = 48_000
TOTAL_FRAMES  = SAMPLE_RATE * 2               # 2 s per synthetic case
MARKER_FRAMES = [SAMPLE_RATE // 2, SAMPLE_RATE, SAMPLE_RATE + SAMPLE_RATE // 2]
FREQS         = [440.0, 550.0, 660.0, 880.0]

PREFIX = "test_"

# ── Dataclasses ───────────────────────────────────────────────────────────────

@dataclass
class SignalSpec:
    """Sine-wave signal for one channel in a synthetic test case."""
    freq_hz: float
    offset_frames: int   # silent prefix before the tone starts
    amplitude: float = 0.5


@dataclass
class ExpectedOutput:
    """One output file expected from desgrana (used only by the real-data runner)."""
    filename: str           # e.g. "test_ch01.wav" or "test_ch01-02.wav"
    src_channels: list[int] # 0-indexed channel(s) in the input WAV


@dataclass
class TestCase:
    """A self-contained test scenario.

    Synthetic cases (channel_signals set): generate WAV from sine waves.
    Fixtures are committed in Tests/fixtures/<name>/ and tested byte-for-byte.

    Real-data cases (source_wav_rel set): truncate an existing WAV file.
    Fixtures are generated on demand in var/tmp/tests/<name>/ and not committed.
    """
    name: str

    # Synthetic: generate an interleaved WAV from per-channel sine waves
    channel_signals: "list[SignalSpec] | None" = None

    # Real-data: copy-truncate from an existing WAV file
    source_wav_rel: "str | None" = None  # relative to desgrana/Tests/
    truncate_frames: int = 0             # 0 = keep all frames
    fadeout_frames:  int = 0             # 0 = no fade-out

    # Session parameters (inferred for real-data from the source WAV header)
    num_channels:    int = 0
    sample_rate:     int = SAMPLE_RATE
    total_frames:    int = 0
    bits_per_sample: int = 32
    format_tag:      int = 3             # 3 = IEEE_FLOAT, 1 = PCM

    # Optional snap file: dict is serialised as JSON in the session directory.
    # The snap is auto-detected by desgrana (no --snap flag needed).
    snap_data:     "dict | None" = None
    snap_filename: str = "test.snap"

    # desgrana invocation
    desgrana_extra_args: list = field(default_factory=list)
    markers:             list = field(default_factory=list)

    # Used only by the real-data runner (None = auto-derive from active channels)
    expected_outputs: "list[ExpectedOutput] | None" = None


# ── Test cases ────────────────────────────────────────────────────────────────

CASES: list = [
    TestCase(
        name="case01_stereo",
        num_channels=2,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),  # 0.25 s silent prefix
        ],
        desgrana_extra_args=["--stereo", "1:2"],
        markers=MARKER_FRAMES,
    ),
    TestCase(
        name="case02_4mono",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),
            SignalSpec(FREQS[2], SAMPLE_RATE // 2),
            SignalSpec(FREQS[3], SAMPLE_RATE * 3 // 4),
        ],
        desgrana_extra_args=[],
        markers=MARKER_FRAMES,
    ),
    TestCase(
        name="case03_mixed",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),
            SignalSpec(FREQS[2], SAMPLE_RATE // 2),
            SignalSpec(FREQS[3], SAMPLE_RATE * 3 // 4),
        ],
        desgrana_extra_args=["--stereo", "3:4"],
        markers=MARKER_FRAMES,
    ),
    TestCase(
        name="case05_snap",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),
            SignalSpec(FREQS[2], SAMPLE_RATE // 2),
            SignalSpec(FREQS[3], SAMPLE_RATE * 3 // 4),
        ],
        # Snap provides channel names; OH_L+OH_R are paired by name, Kick/Snare stay mono.
        snap_data={
            "active_scene": "I:/TEST_SHOW/Test_Scene.snap",
            "ae_data": {
                "ch": {
                    "1": {"name": "Kick"},
                    "2": {"name": "Snare"},
                    "3": {"name": "OH_L"},
                    "4": {"name": "OH_R"},
                },
            },
        },
        desgrana_extra_args=["--short-names"],
        markers=MARKER_FRAMES,
    ),
    TestCase(
        name="case06_silent",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=SAMPLE_RATE // 2,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], 0),
            SignalSpec(FREQS[2], SAMPLE_RATE // 2),  # ch3: offset past end -> stays +0.0, silent
            SignalSpec(FREQS[3], 0),
        ],
        desgrana_extra_args=[],
        markers=[],
    ),
    # case08: 4 Wing channels each routing to a USB stereo input (BD/SD/Toms/OH).
    # Reproduces the pairing scenario from issue #2 (xt99): USB stereo sources
    # where io.in.USB.N.mode="ST" drives pair detection, not L/R name suffixes.
    # 8 WAV channels: USB inputs 1-8, grouped as pairs (1,2),(3,4),(5,6),(7,8).
    # Even channels have no name; pairing comes entirely from the snap.
    TestCase(
        name="case08_usb_stereo",
        num_channels=8,
        sample_rate=SAMPLE_RATE,
        total_frames=SAMPLE_RATE // 2,
        channel_signals=[
            SignalSpec(FREQS[0], 0),                    # USB 1: BD L
            SignalSpec(FREQS[0], SAMPLE_RATE // 8),     # USB 2: BD R
            SignalSpec(FREQS[1], 0),                    # USB 3: SD L
            SignalSpec(FREQS[1], SAMPLE_RATE // 8),     # USB 4: SD R
            SignalSpec(FREQS[2], 0),                    # USB 5: Toms L
            SignalSpec(FREQS[2], SAMPLE_RATE // 8),     # USB 6: Toms R
            SignalSpec(FREQS[3], 0),                    # USB 7: OH L
            SignalSpec(FREQS[3], SAMPLE_RATE // 8),     # USB 8: OH R
        ],
        snap_data={
            "active_scene": "U:/USB Stereo Show/USB stereo.snap",
            "ae_data": {
                "ch": {
                    "1": {"name": "BD",   "in": {"conn": {"grp": "USB", "in": 1}}},
                    "2": {"name": "SD",   "in": {"conn": {"grp": "USB", "in": 3}}},
                    "3": {"name": "Toms", "in": {"conn": {"grp": "USB", "in": 5}}},
                    "4": {"name": "OH",   "in": {"conn": {"grp": "USB", "in": 7}}},
                },
                "io": {
                    "in": {
                        "USB": {
                            "1": {"mode": "ST"},
                            "3": {"mode": "ST"},
                            "5": {"mode": "ST"},
                            "7": {"mode": "ST"},
                        }
                    }
                },
            },
        },
        desgrana_extra_args=[],
        markers=[],
    ),
    # case04: truncated from the real SD Card session WAV.
    # Not committed; skipped automatically when the source file is absent.
    TestCase(
        name="case04_real",
        source_wav_rel="SD Card/00000001.WAV",
        truncate_frames=SAMPLE_RATE * 7,  # 7 s
        fadeout_frames=SAMPLE_RATE,        # 1-s linear fade-out
        desgrana_extra_args=[],
        markers=[],
        expected_outputs=None,            # derived from non-silent channels
    ),
]

# ── WAV I/O helpers ───────────────────────────────────────────────────────────

def _pack_chunk(fourcc: bytes, data: bytes) -> bytes:
    assert len(fourcc) == 4
    return fourcc + struct.pack("<I", len(data)) + data


def find_data_chunk(path: str) -> "tuple[int, int]":
    """Return (offset_of_first_data_byte, data_size) in a WAV file."""
    with open(path, "rb") as f:
        hdr = f.read(12)
        if hdr[:4] != b"RIFF" or hdr[8:12] != b"WAVE":
            raise ValueError(f"Not a WAV: {path}")
        while True:
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                raise ValueError(f"'data' chunk not found in {path}")
            tag, size = struct.unpack("<4sI", chunk_hdr)
            if tag == b"data":
                return f.tell(), size
            f.seek(size + (size & 1), 1)


def read_wav_fmt(path: str) -> "tuple[int, int, int, int]":
    """Return (format_tag, num_channels, sample_rate, bits_per_sample)."""
    with open(path, "rb") as f:
        hdr = f.read(12)
        if hdr[:4] != b"RIFF" or hdr[8:12] != b"WAVE":
            raise ValueError(f"Not a WAV: {path}")
        while True:
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                raise ValueError(f"'fmt ' chunk not found in {path}")
            tag, size = struct.unpack("<4sI", chunk_hdr)
            if tag == b"fmt ":
                data = f.read(size)
                fmt_tag = struct.unpack_from("<H", data, 0)[0]
                nc      = struct.unpack_from("<H", data, 2)[0]
                sr      = struct.unpack_from("<I", data, 4)[0]
                bps     = struct.unpack_from("<H", data, 14)[0]
                return fmt_tag, nc, sr, bps
            f.seek(size + (size & 1), 1)


def read_data_bytes(path: str) -> bytes:
    offset, size = find_data_chunk(path)
    with open(path, "rb") as f:
        f.seek(offset)
        return f.read(size)


def make_channel_samples(spec: SignalSpec, total_frames: int, sample_rate: int) -> "ar.array":
    """Generate a float32 array of total_frames samples for one channel."""
    buf = ar.array("f", [0.0] * total_frames)
    for i in range(spec.offset_frames, total_frames):
        t = (i - spec.offset_frames) / sample_rate
        buf[i] = spec.amplitude * math.sin(2.0 * math.pi * spec.freq_hz * t)
    return buf


def write_wav_synthetic(path: str, case: TestCase) -> None:
    """Write a multichannel 32-bit float WAV from SignalSpecs."""
    nc, sr, nf = case.num_channels, case.sample_rate, case.total_frames
    channels = [make_channel_samples(sig, nf, sr) for sig in case.channel_signals]

    pcm = ar.array("f", (channels[c][f] for f in range(nf) for c in range(nc)))
    pcm_bytes = pcm.tobytes()

    block_align = nc * 4
    byte_rate   = sr * block_align
    fmt = struct.pack("<HHIIHH", 3, nc, sr, byte_rate, block_align, 32) + struct.pack("<H", 0)
    riff_data = b"WAVE" + _pack_chunk(b"fmt ", fmt) + _pack_chunk(b"data", pcm_bytes)
    with open(path, "wb") as f:
        f.write(_pack_chunk(b"RIFF", riff_data))
    size_mb = len(pcm_bytes) / (1024 * 1024)
    print(f"  Generated: {os.path.basename(path)}"
          f"  ({nc} ch, {sr} Hz, 32-bit float, {nf} frames = {nf/sr:.1f} s, {size_mb:.1f} MB)")


def write_wav_from_source(path: str, source_path: str, case: TestCase) -> int:
    """Truncate and optionally fade-out a source WAV, write to path."""
    nc  = case.num_channels
    bps = case.bits_per_sample // 8

    data_offset, data_size = find_data_chunk(source_path)
    read_size = min(case.truncate_frames * nc * bps, data_size) if case.truncate_frames > 0 else data_size
    with open(source_path, "rb") as f:
        f.seek(data_offset)
        audio = bytearray(f.read(read_size))

    actual_frames = len(audio) // (nc * bps)

    if case.fadeout_frames > 0 and case.format_tag == 3 and bps == 4:
        _apply_fadeout_float32(audio, actual_frames, case.fadeout_frames, nc)

    case.total_frames = actual_frames

    block_align = nc * bps
    byte_rate   = case.sample_rate * block_align
    fmt = (struct.pack("<HHIIHH",
                       case.format_tag, nc, case.sample_rate,
                       byte_rate, block_align, case.bits_per_sample)
           + struct.pack("<H", 0))
    riff_data = b"WAVE" + _pack_chunk(b"fmt ", fmt) + _pack_chunk(b"data", bytes(audio))
    with open(path, "wb") as f:
        f.write(_pack_chunk(b"RIFF", riff_data))
    size_mb = len(audio) / (1024 * 1024)
    print(f"  Generated: {os.path.basename(path)}"
          f"  ({nc} ch, {case.sample_rate} Hz, {case.bits_per_sample}-bit,"
          f" {actual_frames} frames = {actual_frames / case.sample_rate:.1f} s, {size_mb:.1f} MB)")
    return actual_frames


def _apply_fadeout_float32(audio: bytearray, total_frames: int, fadeout_frames: int, nc: int) -> None:
    """Linear fade-out on the last fadeout_frames frames, in-place (float32 only)."""
    fade_start = max(0, total_frames - fadeout_frames)
    frame_size = nc * 4
    fmt_str    = f"<{nc}f"
    actual_fade = total_frames - fade_start
    for i in range(actual_fade):
        ramp    = 1.0 - i / actual_fade
        offset  = (fade_start + i) * frame_size
        samples = struct.unpack_from(fmt_str, audio, offset)
        struct.pack_into(fmt_str, audio, offset, *(s * ramp for s in samples))


def extract_channel_bytes(interleaved: bytes, ch: int, nc: int, bps: int) -> bytes:
    """Extract one mono channel from an interleaved byte buffer."""
    stride = nc * bps
    nf     = len(interleaved) // stride
    out    = bytearray(nf * bps)
    for f in range(nf):
        src = f * stride + ch * bps
        out[f * bps:(f + 1) * bps] = interleaved[src:src + bps]
    return bytes(out)


def extract_stereo_bytes(interleaved: bytes, left: int, right: int, nc: int, bps: int) -> bytes:
    """Extract a stereo pair as interleaved L/R from a multichannel byte buffer."""
    stride  = nc * bps
    nf      = len(interleaved) // stride
    out_bps = 2 * bps
    out     = bytearray(nf * out_bps)
    for f in range(nf):
        lsrc = f * stride + left  * bps
        rsrc = f * stride + right * bps
        dst  = f * out_bps
        out[dst:dst + bps]             = interleaved[lsrc:lsrc + bps]
        out[dst + bps:dst + out_bps]   = interleaved[rsrc:rsrc + bps]
    return bytes(out)


def find_active_channels(data: bytes, nc: int, bps: int) -> list:
    """Return sorted list of 0-indexed channels with at least one non-zero sample."""
    stride = nc * bps
    nf     = len(data) // stride
    zero   = bytes(bps)
    active = []
    for c in range(nc):
        for f in range(nf):
            offset = f * stride + c * bps
            if data[offset:offset + bps] != zero:
                active.append(c)
                break
    return active


# ── SE_LOG.BIN generation ─────────────────────────────────────────────────────

def write_selog_bin(path: str, nc: int, sample_rate: int,
                    num_frames: int, markers: list,
                    ts: "int | None" = None) -> None:
    """Write a 2048-byte SE_LOG.BIN for a single-take session.

    Pass ts=0 for committed fixtures to keep the file deterministic.
    """
    buf = bytearray(2048)
    if ts is None:
        ts = int(time.time()) & 0xFFFF_FFFF

    def w32(offset: int, value: int) -> None:
        struct.pack_into("<I", buf, offset, value & 0xFFFF_FFFF)

    w32(0,  ts)
    w32(4,  nc)
    w32(8,  sample_rate)
    w32(12, ts)
    w32(16, 1)                           # num_takes
    w32(20, len(markers))
    w32(24, num_frames)                  # totalLength: frames per channel
    w32(28, num_frames * nc)             # takeSizes[0]: interleaved sample count

    for i, m in enumerate(markers[:100]):
        w32(1052 + i * 4, m)

    buf[1553:1558] = b"test\x00"

    with open(path, "wb") as f:
        f.write(buf)
    print(f"  Generated: SE_LOG.BIN  ({nc} ch, {sample_rate} Hz, {len(markers)} markers)")


# ── Marker verification (used by real-data runner) ────────────────────────────

def read_cue_positions(wav_path: str) -> list:
    """Return cue point sample positions from a WAV file."""
    with open(wav_path, "rb") as f:
        hdr = f.read(12)
        if hdr[:4] != b"RIFF" or hdr[8:12] != b"WAVE":
            return []
        while True:
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                break
            tag, size = struct.unpack("<4sI", chunk_hdr)
            if tag == b"cue ":
                body  = f.read(size)
                count = struct.unpack_from("<I", body, 0)[0]
                return [struct.unpack_from("<I", body, 4 + i * 24 + 4)[0] for i in range(count)]
            f.seek(size + (size & 1), 1)
    return []


def read_midi_marker_events(mid_path: str) -> list:
    """Parse a Type-0 SMPTE SMF and return (absolute_tick, name) for every marker."""
    with open(mid_path, "rb") as f:
        data = f.read()

    pos = [0]

    def rb(n: int) -> bytes:
        chunk = data[pos[0]:pos[0] + n]; pos[0] += n; return chunk

    def ru32() -> int: return struct.unpack(">I", rb(4))[0]
    def ru16() -> int: return struct.unpack(">H", rb(2))[0]

    def varlen() -> int:
        value = 0
        while True:
            b = data[pos[0]]; pos[0] += 1
            value = (value << 7) | (b & 0x7F)
            if not (b & 0x80):
                break
        return value

    assert data[0:4] == b"MThd", "Missing MThd"
    pos[0] = 4
    ru32(); fmt = ru16(); n_tracks = ru16(); division = ru16()
    assert fmt == 0 and n_tracks == 1, f"Expected Type-0 SMF, got format={fmt} tracks={n_tracks}"
    assert division == 0xE728, f"Expected SMPTE division 0xE728, got 0x{division:04X}"

    assert data[pos[0]:pos[0] + 4] == b"MTrk", "Missing MTrk"
    pos[0] += 4
    track_len = ru32()
    track_end = pos[0] + track_len

    markers: list = []
    abs_tick = 0
    while pos[0] < track_end:
        delta    = varlen()
        abs_tick += delta
        status   = data[pos[0]]; pos[0] += 1
        if status == 0xFF:
            meta_type = data[pos[0]]; pos[0] += 1
            meta_len  = varlen()
            meta_data = rb(meta_len)
            if meta_type == 0x06:
                markers.append((abs_tick, meta_data.decode("utf-8")))
        elif status & 0x80:
            high = (status >> 4) & 0xF
            if high in (0x8, 0x9, 0xA, 0xB, 0xE):
                pos[0] += 2
            elif high in (0xC, 0xD):
                pos[0] += 1
    return markers


def verify_markers(case: TestCase, output_dir: str) -> int:
    """Verify cue chunks in output WAVs and MIDI file. Returns failure count."""
    failures = 0
    wav_files = sorted(f for f in os.listdir(output_dir) if f.lower().endswith(".wav"))
    for fname in wav_files:
        positions = read_cue_positions(os.path.join(output_dir, fname))
        if positions == case.markers:
            if case.markers:
                print(f"  OK    {fname}  cue = {positions}")
        else:
            print(f"  FAIL  {fname}  cue = {positions}  (expected {case.markers})")
            failures += 1

    mid_path = os.path.join(output_dir, f"{PREFIX}markers.mid")
    if not case.markers:
        if os.path.isfile(mid_path):
            print(f"  FAIL  unexpected MIDI file: {PREFIX}markers.mid")
            failures += 1
        return failures

    if not os.path.isfile(mid_path):
        print(f"  FAIL  MIDI file not found: {PREFIX}markers.mid")
        return failures + 1

    events   = read_midi_marker_events(mid_path)
    expected = [(round(s / case.sample_rate * 1000), f"Marker {i + 1}")
                for i, s in enumerate(case.markers)]
    if events == expected:
        print(f"  OK    {PREFIX}markers.mid  {events}")
    else:
        print(f"  FAIL  {PREFIX}markers.mid")
        print(f"         got      : {events}")
        print(f"         expected : {expected}")
        failures += 1
    return failures


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
            f.seek(chunk_size, 1)


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


# ── CLI error handling tests ──────────────────────────────────────────────────

def run_cli_error_tests(binary: str) -> int:
    """Test CLI error exit codes and stderr messages. Returns failure count."""
    import tempfile

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
    import tempfile, shutil
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copy(os.path.join(session_dir, "00000001.wav"),
                    os.path.join(tmp, "00000001.wav"))
        check("--info (no SE_LOG.BIN)",
              [tmp, "--info"], 0,
              stdout_has=["No SE_LOG.bin found", "00000001.wav"])

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


# ── Main ──────────────────────────────────────────────────────────────────────

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

    binary = find_binary(args[0] if args else None, desgrana_dir)
    print(f"Binary : {binary}")
    if generate_mode:
        print(f"Mode   : generate  (writing to {fixtures_dir})")
    print()

    if generate_mode:
        for case in CASES:
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
    total_failures += run_fallback_tests(binary, var_dir)
    total_failures += run_ixml_test(binary, var_dir)

    for case in CASES:
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
