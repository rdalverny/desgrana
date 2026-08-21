# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""SE_LOG.BIN generation for synthetic sessions."""

from __future__ import annotations

import struct
import time


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
