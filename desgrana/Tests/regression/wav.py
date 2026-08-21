# SPDX-FileCopyrightText: 2026 Romain d'Alverny
# SPDX-License-Identifier: MIT
"""WAV read/write/extract helpers used to generate inputs and check outputs."""

from __future__ import annotations

import array as ar
import math
import os
import struct

from .test_model import FORMAT_IEEE_FLOAT, FORMAT_PCM, INT_PEAK, SignalSpec, TestCase


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


def quantise_pcm(samples, bits: int) -> bytes:
    """Pack float samples in [-1, 1] as little-endian signed integer PCM."""
    peak = INT_PEAK[bits]
    out  = bytearray()
    for s in samples:
        value = int(max(-1.0, min(1.0, s)) * peak)

        # 24-bit has no struct code: pack as int32 and drop the high byte.
        # Two's complement stays valid because value fits the 24-bit signed range.
        if bits == 24:
            out += struct.pack("<i", value)[:3]
        elif bits == 16:
            out += struct.pack("<h", value)
        else:
            out += struct.pack("<i", value)
    return bytes(out)


def write_wav_synthetic(path: str, case: TestCase) -> None:
    """Write a multichannel WAV from SignalSpecs, at the case's depth and format tag."""
    nc, sr, nf = case.num_channels, case.sample_rate, case.total_frames
    bits = case.bits_per_sample
    bps  = bits // 8
    assert case.format_tag != FORMAT_IEEE_FLOAT or bits == 32, \
        f"{case.name}: IEEE float fixtures are 32-bit only, got {bits}"

    channels = [make_channel_samples(sig, nf, sr) for sig in case.channel_signals]
    interleaved = (channels[c][f] for f in range(nf) for c in range(nc))

    # Integer cases are quantised from the same float reference, so a 16/24/32-bit
    # fixture carries the same waveform as its float counterpart.
    if case.format_tag == FORMAT_PCM:
        pcm_bytes = quantise_pcm(interleaved, bits)
        depth_label = f"{bits}-bit int"
    else:
        pcm_bytes = ar.array("f", interleaved).tobytes()
        depth_label = "32-bit float"

    block_align = nc * bps
    byte_rate   = sr * block_align
    fmt = (struct.pack("<HHIIHH", case.format_tag, nc, sr, byte_rate, block_align, bits)
           + struct.pack("<H", 0))
    riff_data = b"WAVE" + _pack_chunk(b"fmt ", fmt) + _pack_chunk(b"data", pcm_bytes)
    with open(path, "wb") as f:
        f.write(_pack_chunk(b"RIFF", riff_data))
    size_mb = len(pcm_bytes) / (1024 * 1024)
    print(f"  Generated: {os.path.basename(path)}"
          f"  ({nc} ch, {sr} Hz, {depth_label}, {nf} frames = {nf/sr:.1f} s, {size_mb:.1f} MB)")


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

    if case.fadeout_frames > 0 and case.format_tag == FORMAT_IEEE_FLOAT and bps == 4:
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
