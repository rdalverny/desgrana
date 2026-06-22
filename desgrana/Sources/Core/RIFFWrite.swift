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

    // 0xFFFF_FFFF signals a >4 GB file (RIFF64); writing a new size would overflow and corrupt the header.
    // Also guard against ordinary overflow for files just under the RIFF64 threshold.
    if currentRiffSize != 0xFFFF_FFFF,
       (0xFFFF_FFFE - currentRiffSize) >= UInt32(chunk.count) {
        let newSize = currentRiffSize + UInt32(chunk.count)
        var sizeLE = newSize.littleEndian
        guard (try? fh.seek(toOffset: 4)) != nil else { return false }
        try? fh.write(contentsOf: Data(bytes: &sizeLE, count: 4))
    }
    return true
}
