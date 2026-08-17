# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""Constants and the dataclasses that describe a test scenario."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

# ── Constants ─────────────────────────────────────────────────────────────────

SAMPLE_RATE   = 48_000
TOTAL_FRAMES  = SAMPLE_RATE * 2               # 2 s per synthetic case
MARKER_FRAMES = [SAMPLE_RATE // 2, SAMPLE_RATE, SAMPLE_RATE + SAMPLE_RATE // 2]
FREQS         = [440.0, 550.0, 660.0, 880.0]

PREFIX = "test_"

# Local-only test data (real captures), git-ignored.
PRIVATE_DIR = "Private"

# WAV `fmt ` format tags.
FORMAT_PCM        = 1
FORMAT_IEEE_FLOAT = 3

# Full-scale peak per integer depth. 2^(bits-1) - 1 so an amplitude of 1.0 never wraps.
INT_PEAK = {16: 2**15 - 1, 24: 2**23 - 1, 32: 2**31 - 1}

# Project version, for the prov chunk check. Read from $DESGRANA_VERSION when set
# (e.g. in the .deb test container, where repo-root VERSION isn't mounted),
# otherwise from the repo-root VERSION file (three levels up: regression/ -> Tests/
# -> desgrana/ -> beriwave/).
_REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "..")
EXPECTED_VERSION = os.environ.get("DESGRANA_VERSION") or open(
    os.path.join(_REPO_ROOT, "VERSION"), encoding="utf-8"
).read().strip()

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
    format_tag:      int = FORMAT_IEEE_FLOAT

    # Optional snap file: dict is serialised as JSON in the session directory.
    # The snap is auto-detected by desgrana (no --snap flag needed).
    snap_data:     "dict | None" = None
    snap_filename: str = "test.snap"

    # desgrana invocation
    desgrana_extra_args: list = field(default_factory=list)
    markers:             list = field(default_factory=list)

    # Used only by the real-data runner (None = auto-derive from active channels)
    expected_outputs: "list[ExpectedOutput] | None" = None

    # Expected iXML track names per output file ({filename: [names]}); None = no check.
    expected_ixml: "dict | None" = None
