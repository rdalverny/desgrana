// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Little-endian byte helpers
//
// Shared codec primitives for the RIFF/WAV readers and writers and the SE_LOG parser.
// Big-endian helpers (MIDI) live with their only user in Markers.swift on purpose.

extension Data {
    mutating func appendLE(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }

    /// Little-endian bytes of `v` as a fresh `Data` (for in-place size patches).
    init(le v: UInt32) { self = Swift.withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    init(le v: UInt64) { self = Swift.withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Reads a little-endian UInt32 at byte `offset`, or 0 if out of range.
    func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}

/// Four ASCII bytes of `b` at `o` as a string (chunk/form ids), or "" if not ASCII.
func fourCC(_ b: [UInt8], _ o: Int) -> String { String(bytes: b[o ..< o + 4], encoding: .ascii) ?? "" }

func leU16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }

func leU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

func leU64(_ b: [UInt8], _ o: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | (UInt64(b[o + $1]) << (8 * $1)) }
}

extension FileHandle {
    /// Seeks to `offset` and overwrites it with `data` (in-place field patch).
    func patch(at offset: UInt64, _ data: Data) throws {
        try seek(toOffset: offset)
        try write(contentsOf: data)
    }
}
