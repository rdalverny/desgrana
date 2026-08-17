# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""Output verification: cue markers, MIDI marker track, bext, and iXML names."""

from __future__ import annotations

import os
import re
import struct

from .test_model import EXPECTED_VERSION, PREFIX, TestCase


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


def read_ixml_names(wav_path: str) -> "list[str] | None":
    """Return <NAME> values from the iXML chunk in document order, or None if absent."""
    with open(wav_path, "rb") as f:
        hdr = f.read(12)
        if hdr[:4] not in (b"RIFF", b"RF64") or hdr[8:12] != b"WAVE":
            return None
        while True:
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                break
            tag, size = struct.unpack("<4sI", chunk_hdr)
            if tag == b"iXML":
                payload = f.read(size).rstrip(b"\x00").decode("utf-8", "replace")
                return re.findall(r"<NAME>(.*?)</NAME>", payload)
            f.seek(size + (size & 1), 1)
    return None


def read_bext(wav_path: str) -> "dict | None":
    """Return the bext chunk fields, or None if absent."""
    with open(wav_path, "rb") as f:
        hdr = f.read(12)
        if hdr[:4] not in (b"RIFF", b"RF64") or hdr[8:12] != b"WAVE":
            return None
        while True:
            chunk_hdr = f.read(8)
            if len(chunk_hdr) < 8:
                break
            tag, size = struct.unpack("<4sI", chunk_hdr)
            if tag == b"bext":
                body = f.read(size)
                return {
                    "originator": body[256:288].split(b"\x00")[0].decode("ascii", "replace"),
                    "orig_ref":   body[288:320].split(b"\x00")[0].decode("ascii", "replace"),
                    "date":       body[320:330].rstrip(b"\x00").decode("ascii", "replace"),
                    "time":       body[330:338].rstrip(b"\x00").decode("ascii", "replace"),
                    "time_ref":   struct.unpack("<Q", body[338:346])[0],
                    "coding":     body[602:].rstrip(b"\x00").decode("ascii", "replace"),
                }
            f.seek(size + (size & 1), 1)
    return None


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


def verify_bext(output_dir: str) -> int:
    """Every output WAV must carry a bext chunk. Synthetic sources have no source
    bext, so Originator is Desgrana, no fabricated timecode, and the coded
    OriginatorReference + CodingHistory identify the build."""
    failures = 0
    for fname in sorted(f for f in os.listdir(output_dir) if f.lower().endswith(".wav")):
        b = read_bext(os.path.join(output_dir, fname))
        ok = (b is not None
              and b["originator"] == "Desgrana"
              and b["time_ref"] == 0
              and b["date"] == "" and b["time"] == ""
              and b["orig_ref"] == ""
              and f"Desgrana {EXPECTED_VERSION}" in b["coding"])
        if ok:
            print(f"  OK    {fname}  bext  {b['coding'].strip()}")
        else:
            print(f"  FAIL  {fname}  bext = {b}")
            failures += 1
    return failures


def verify_ixml(case: TestCase, output_dir: str) -> int:
    """Verify embedded iXML track names against case.expected_ixml. Returns failure count."""
    if not case.expected_ixml:
        return 0
    failures = 0
    for fname, expected in case.expected_ixml.items():
        got = read_ixml_names(os.path.join(output_dir, fname))
        if got == expected:
            print(f"  OK    {fname}  iXML = {got}")
        else:
            print(f"  FAIL  {fname}  iXML = {got}  (expected {expected})")
            failures += 1
    return failures
