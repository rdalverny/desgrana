// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - SE_LOG.bin layout (2048 bytes, little-endian)
//
// Format based on reverse engineering by Patrick-Gilles Maillot
// see https://github.com/pmaillot/X32-Behringer/blob/master/X32cpXliveMarkers.c#L247
//
//  Offset  Size    Content
//  0       4       Session timestamp (Unix epoch: seconds since 1970-01-01 UTC)
//  4       4       Number of channels (uint32)
//  8       4       Sample rate (uint32)
//  12      4       Session timestamp (duplicate)
//  16      4       Number of takes (.wav files)
//  20      4       Number of markers
//  24      4       Total length in samples
//  28      1024    Take sizes: 256 × uint32
//  1052    400     Marker positions: 100 × uint32 (in samples)
//  1553    16      Session name (ASCII, null-terminated) — Wing layout
//  ...     ...     Zero-padded to 2047

public struct SessionInfo {
    public let timestamp: UInt32
    public let numChannels: Int
    public let sampleRate: Int
    public let numTakes: Int
    public let numMarkers: Int
    public let totalLength: UInt32
    public let takeSizes: [UInt32]
    public let markerSamples: [UInt32]
    public let sessionName: String

    public var totalDuration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalLength) / Double(sampleRate)
    }
}

// MARK: - Data helpers

extension Data {
    func asciiString(at offset: Int, maxLength: Int) -> String {
        guard offset + maxLength <= count else { return "" }
        let slice = self[offset ..< offset + maxLength]
        if let end = slice.firstIndex(of: 0) {
            return String(data: self[offset ..< end], encoding: .ascii) ?? ""
        }
        return String(data: slice, encoding: .ascii) ?? ""
    }
}

// MARK: - Parser

public enum SELogError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case fileTooSmall(Int)

    public var description: String {
        switch self {
        case .fileNotFound(let url): return "SE_LOG.bin not found at \(url.path)"
        case .fileTooSmall(let sz):  return "SE_LOG.bin too small (\(sz) bytes, expected ≥28)"
        }
    }
}

public func parseSELog(at url: URL) throws -> SessionInfo {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw SELogError.fileNotFound(url)
    }

    var data = try Data(contentsOf: url)
    if data.count < 28 {
        throw SELogError.fileTooSmall(data.count)
    }
    // Pad to 2048 if needed
    if data.count < 2048 {
        data.append(Data(count: 2048 - data.count))
    }

    let timestamp   = data.u32(at: 0)
    let numChannels = Int(data.u32(at: 4))
    let sampleRate  = Int(data.u32(at: 8))
    let numTakes    = Int(data.u32(at: 16))
    let numMarkers  = Int(data.u32(at: 20))
    let totalLength = data.u32(at: 24)

    // Take sizes (offset 28, up to 256 entries)
    let takeCount = min(numTakes, 256)
    var takeSizes: [UInt32] = []
    for i in 0 ..< takeCount {
        takeSizes.append(data.u32(at: 28 + i * 4))
    }

    // Markers (offset 1052, up to 100 entries)
    let markerCount = min(numMarkers, 100)
    var markers: [UInt32] = []
    for i in 0 ..< markerCount {
        let mk = data.u32(at: 1052 + i * 4)
        if mk > 0 { markers.append(mk) }  // 0 = unset slot in Wing's fixed-size marker array
    }

    // Session name (offset 1553, 16 chars max)
    let name = data.asciiString(at: 1553, maxLength: 16)

    return SessionInfo(
        timestamp: timestamp,
        numChannels: numChannels,
        sampleRate: sampleRate,
        numTakes: numTakes,
        numMarkers: numMarkers,
        totalLength: totalLength,
        takeSizes: takeSizes,
        markerSamples: markers,
        sessionName: name.isEmpty ? String(format: "%08X", timestamp) : name
    )
}

// MARK: - Display

public func formatSamples(_ n: UInt32) -> String {
    let digits = String(n).reversed().map { String($0) }
    var groups: [String] = []
    var i = 0
    while i < digits.count {
        groups.append(digits[i ..< min(i + 3, digits.count)].reversed().joined())
        i += 3
    }
    return groups.reversed().joined(separator: "\u{202F}")
}

public func formatTime(_ seconds: Double) -> String {
    // Guard against non-finite input (e.g. a sample position divided by a zero
    // sample rate from a corrupt SE_LOG.bin): Int(inf)/Int(nan) is a hard trap.
    guard seconds.isFinite else { return "--:--.---" }
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = seconds.truncatingRemainder(dividingBy: 60)
    if h > 0 {
        return String(format: "%02d:%02d:%06.3f", h, m, s)
    }
    return String(format: "%02d:%06.3f", m, s)
}

public func printSessionInfo(_ info: SessionInfo) {
    print("  Session name : \(info.sessionName)")
    print("  Timestamp    : \(String(format: "%08X", info.timestamp))")
    print("  Channels     : \(info.numChannels)")
    print("  Sample rate  : \(info.sampleRate) Hz")
    print("  Total length : \(formatTime(info.totalDuration)) (\(formatSamples(info.totalLength)) samples)")
    print("  Markers      : \(info.numMarkers)")

    if !info.markerSamples.isEmpty {
        print()
        for (i, mk) in info.markerSamples.enumerated() {
            let t = Double(mk) / Double(info.sampleRate)
            print("    Marker \(String(format: "%3d", i + 1)) : \(formatTime(t))  (sample \(mk))")
        }
    }

    print("  Takes (files): \(info.numTakes)")
}
