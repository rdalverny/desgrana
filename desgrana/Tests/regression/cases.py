# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""Synthetic test cases with committed fixtures. Real-data cases live in
Tests/Private/cases.py. Add one, then run --generate.

  case01_stereo  2-ch WAV, --stereo 1:2      -> 1 stereo output + markers
  case02_4mono   4-ch WAV, all mono          -> 4 mono outputs + markers
  case03_mixed   4-ch WAV, --stereo 3:4      -> 2 mono + 1 stereo + markers
  case05_snap    4-ch WAV + .snap file       -> stereo pair + 2 mono (from snap) + markers
"""

from __future__ import annotations

from .private import PRIVATE_CASES
from .test_model import (
    FORMAT_PCM,
    FREQS,
    MARKER_FRAMES,
    SAMPLE_RATE,
    TOTAL_FRAMES,
    SignalSpec,
    TestCase,
)

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
        expected_ixml={
            "Kick.wav":  ["Kick"],
            "Snare.wav": ["Snare"],
            "OH.wav":    ["OH L", "OH R"],
        },
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
        expected_ixml={
            "test_ch01-02_BD.wav":   ["BD L", "BD R"],
            "test_ch03-04_SD.wav":   ["SD L", "SD R"],
            "test_ch05-06_Toms.wav": ["Toms L", "Toms R"],
            "test_ch07-08_OH.wav":   ["OH L", "OH R"],
        },
    ),
    # case09: non-ASCII channel names (accents + œ ligature). Exercises the
    # Unicode string paths — snap JSON parsing, output filenames, iXML track
    # names — that ASCII fixtures never reach (Foundation has ASCII fast paths).
    TestCase(
        name="case09_nonascii",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),
            SignalSpec(FREQS[2], SAMPLE_RATE // 2),
            SignalSpec(FREQS[3], SAMPLE_RATE * 3 // 4),
        ],
        snap_data={
            "active_scene": "I:/RÉPÉTITION/Générale.snap",
            "ae_data": {
                "ch": {
                    "1": {"name": "Café"},
                    "2": {"name": "Naïve"},
                    "3": {"name": "Chœur_L"},
                    "4": {"name": "Chœur_R"},
                },
            },
        },
        desgrana_extra_args=["--short-names"],
        markers=MARKER_FRAMES,
        expected_ixml={
            "Café.wav":  ["Café"],
            "Naïve.wav": ["Naïve"],
            "Chœur.wav": ["Chœur L", "Chœur R"],
        },
    ),
    # case10: 24-bit int PCM. The int24 demux branch copies byte by byte and shares
    # no code with the 2/4/8-byte typed-pointer branches, so no other fixture reaches
    # it. Channel 3 is silent to exercise silence culling at that depth as well.
    TestCase(
        name="case10_int24",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        bits_per_sample=24,
        format_tag=FORMAT_PCM,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),
            SignalSpec(FREQS[2], 0, amplitude=0.0),     # silent: must be culled
            SignalSpec(FREQS[3], SAMPLE_RATE // 2),
        ],
        desgrana_extra_args=["--stereo", "1:2"],        # also covers demuxStereo at 24 bits
        markers=MARKER_FRAMES,
    ),
    # case11: 16-bit int PCM, the last bit depth without a fixture.
    TestCase(
        name="case11_int16",
        num_channels=4,
        sample_rate=SAMPLE_RATE,
        total_frames=TOTAL_FRAMES,
        bits_per_sample=16,
        format_tag=FORMAT_PCM,
        channel_signals=[
            SignalSpec(FREQS[0], 0),
            SignalSpec(FREQS[1], SAMPLE_RATE // 4),
            SignalSpec(FREQS[2], SAMPLE_RATE // 2),
            SignalSpec(FREQS[3], SAMPLE_RATE * 3 // 4),
        ],
        desgrana_extra_args=["--stereo", "3:4"],
        markers=MARKER_FRAMES,
    ),
]

# Local-only cases from Tests/Private/; empty on a clone.
CASES += PRIVATE_CASES
