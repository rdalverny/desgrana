// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - RIFF chunk append (write only)
//
// Shared low-level helper to append a chunk to an already-written WAV file and
// keep the RIFF size header consistent. Used by the cue (markers), iXML and
// provenance writers. The audio `data` chunk is never read or rewritten, so
// appending metadata chunks is transparent to the signal.

extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

/// Appends a RIFF chunk (`id` + payload, padded to an even length) to the WAV at
/// `url` and grows the RIFF size field (offset 4) accordingly.
///
/// `id` must be exactly 4 ASCII bytes. On RF64 files the size field holds the
/// 0xFFFF_FFFF sentinel and the real size lives in `ds64`; we leave it untouched
/// rather than corrupt the header (the chunk is still written at EOF).
@discardableResult
func appendRIFFChunk(to url: URL, id: String, payload: Data) -> Bool {
    guard let fh = try? FileHandle(forUpdating: url) else { return false }
    defer { try? fh.close() }

    // Read current RIFF size (offset 4, 4 bytes LE).
    guard (try? fh.seek(toOffset: 4)) != nil,
          let riffSizeBytes = try? fh.read(upToCount: 4),
          riffSizeBytes.count == 4 else { return false }
    let currentRiffSize = riffSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

    // id(4) + size(4) + payload + RIFF pad byte to even length.
    var chunk = Data()
    chunk.append(contentsOf: id.utf8)
    chunk.appendLE(UInt32(payload.count))
    chunk.append(payload)
    if payload.count % 2 == 1 { chunk.append(0) }

    guard (try? fh.seekToEnd()) != nil,
          (try? fh.write(contentsOf: chunk)) != nil else { return false }

    if currentRiffSize == 0xFFFF_FFFF {
        // RF64 (>4 GB): the real RIFF size is a 64-bit field in the ds64 chunk
        // (file offset 20 = 12-byte header + 8-byte ds64 chunk header). Grow it there.
        growRF64RIFFSize(fh, by: UInt64(chunk.count))
    } else if (0xFFFF_FFFE - currentRiffSize) >= UInt32(chunk.count) {
        // Plain RIFF: grow the 32-bit size at offset 4, guarding against overflow.
        let newSize = currentRiffSize + UInt32(chunk.count)
        var sizeLE = newSize.littleEndian
        guard (try? fh.seek(toOffset: 4)) != nil else { return false }
        try? fh.write(contentsOf: Data(bytes: &sizeLE, count: 4))
    }
    return true
}

/// Grows the RF64 `ds64` riffSize field by `delta`, if the file is a well-formed
/// RF64 with `ds64` as its first chunk (riffSize at file offset 20).
private func growRF64RIFFSize(_ fh: FileHandle, by delta: UInt64) {
    guard (try? fh.seek(toOffset: 12)) != nil,
          let head = try? fh.read(upToCount: 8), head.count == 8,
          String(bytes: head[0 ..< 4], encoding: .ascii) == "ds64",
          (try? fh.seek(toOffset: 20)) != nil,
          let cur = try? fh.read(upToCount: 8), cur.count == 8 else { return }
    let bytes = [UInt8](cur)
    let current = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(bytes[$1]) << (8 * $1)) }
    var le = (current &+ delta).littleEndian
    guard (try? fh.seek(toOffset: 20)) != nil else { return }
    try? fh.write(contentsOf: Data(bytes: &le, count: 8))
}
