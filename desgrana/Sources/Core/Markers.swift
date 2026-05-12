// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Data helpers (write only)

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendBE(_ value: UInt16) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendBE(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }

    /// Appends a MIDI variable-length integer (big-endian, 7 bits/byte, MSB continuation flag).
    mutating func appendVarLen(_ value: UInt32) {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(v & 0x7F))
            v >>= 7
        } while v > 0
        // bytes is little-endian; emit most-significant group first with continuation bits
        for i in stride(from: bytes.count - 1, through: 0, by: -1) {
            append(i == 0 ? bytes[i] : bytes[i] | 0x80)
        }
    }
}

// MARK: - cue chunk

/// Appends a RIFF `cue ` chunk to each WAV file in `urls`.
public func writeCueChunks(to urls: [URL], markers: [UInt32]) {
    guard !markers.isEmpty else { return }
    for url in urls {
        writeCueChunk(to: url, markers: markers)
    }
}

private func writeCueChunk(to url: URL, markers: [UInt32]) {
    guard let fh = try? FileHandle(forUpdating: url) else { return }
    defer { try? fh.close() }

    // Read current RIFF size (offset 4, 4 bytes LE)
    guard (try? fh.seek(toOffset: 4)) != nil,
          let riffSizeBytes = try? fh.read(upToCount: 4),
          riffSizeBytes.count == 4 else { return }
    let currentRiffSize = riffSizeBytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

    // Build cue chunk
    // Structure: "cue " + size(4) + count(4) + N × { id(4) position(4) "data"(4) chunkStart(4) blockStart(4) sampleOffset(4) }
    let n = UInt32(markers.count)
    let chunkDataSize = 4 + n * 24

    var chunk = Data()
    chunk.append(contentsOf: "cue ".utf8)
    chunk.appendLE(chunkDataSize)
    chunk.appendLE(n)
    for (i, sample) in markers.enumerated() {
        chunk.appendLE(UInt32(i + 1))       // id
        chunk.appendLE(sample)              // position (= sampleOffset for non-playlist)
        chunk.append(contentsOf: "data".utf8)
        chunk.appendLE(0)                   // chunkStart
        chunk.appendLE(0)                   // blockStart
        chunk.appendLE(sample)              // sampleOffset
    }

    // Append chunk and update RIFF size (skip update if already maxed out)
    guard (try? fh.seekToEnd()) != nil,
          (try? fh.write(contentsOf: chunk)) != nil else { return }

    // 0xFFFF_FFFF signals a >4 GB file (RIFF64); writing a new size would overflow and corrupt the header.
    // Also guard against ordinary overflow for files just under the RIFF64 threshold.
    if currentRiffSize != 0xFFFF_FFFF,
       (0xFFFF_FFFE - currentRiffSize) >= UInt32(chunk.count) {
        let newSize = currentRiffSize + UInt32(chunk.count)
        var sizeLE = newSize.littleEndian
        guard (try? fh.seek(toOffset: 4)) != nil else { return }
        try? fh.write(contentsOf: Data(bytes: &sizeLE, count: 4))
    }
}

// MARK: - MIDI SMF export

/// Exports markers as a Standard MIDI File (type 0, SMPTE 25 fps × 40 ticks/frame = 1 000 ticks/s).
/// Logic Pro (and every modern DAW) imports this file and places markers at the correct absolute
/// time positions, independent of the project tempo.
public func exportMIDIMarkers(_ info: SessionInfo, to outputDir: URL, prefix: String) {
    guard !info.markerSamples.isEmpty else { return }

    let sr = Double(info.sampleRate)
    // SMPTE 25 fps × 40 ticks/frame → 1 000 ticks per second (absolute, tempo-independent)
    let ticksPerSecond: Double = 1_000.0

    var trackBody = Data()
    var prevTick: UInt32 = 0

    // Track name meta event (delta = 0)
    trackBody.append(contentsOf: [0x00, 0xFF, 0x03])         // meta type 0x03 = track name
    trackBody.appendVarLen(UInt32("Markers".utf8.count))
    trackBody.append(contentsOf: "Markers".utf8)

    for (i, sample) in info.markerSamples.enumerated() {
        let tick = UInt32((Double(sample) / sr * ticksPerSecond).rounded())
        let delta = tick >= prevTick ? tick - prevTick : 0  // markers should always be ordered; guard against corrupt data
        prevTick = tick
        trackBody.appendVarLen(delta)
        let name = "Marker \(i + 1)"
        trackBody.append(contentsOf: [0xFF, 0x06])             // marker meta event
        trackBody.appendVarLen(UInt32(name.utf8.count))
        trackBody.append(contentsOf: name.utf8)
    }

    // End of track
    trackBody.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])

    var smf = Data()

    // MThd
    smf.append(contentsOf: "MThd".utf8)
    smf.appendBE(UInt32(6))     // chunk length always 6
    smf.appendBE(UInt16(0))     // format 0 (single track)
    smf.appendBE(UInt16(1))     // 1 track
    // SMPTE division: bit 15 = 1; upper byte = −25 (0xE7); lower byte = 40 ticks/frame (0x28)
    smf.append(contentsOf: [0xE7, 0x28])

    // MTrk
    smf.append(contentsOf: "MTrk".utf8)
    smf.appendBE(UInt32(trackBody.count))
    smf.append(trackBody)

    let midiURL = outputDir.appendingPathComponent("\(prefix)markers.mid")
    do {
        try smf.write(to: midiURL)
        print("  Markers MIDI: \(midiURL.path)")
    } catch {
        print("  Warning: could not write MIDI markers: \(error)")
    }
}

// MARK: - CSV / TXT export

public func exportMarkers(_ info: SessionInfo, to outputDir: URL, prefix: String) {
    guard !info.markerSamples.isEmpty else { return }

    let sr = Double(info.sampleRate)

    // CSV
    let csvURL = outputDir.appendingPathComponent("\(prefix)markers.csv")
    var csv = "marker,time_seconds,time_formatted,sample_position\n"
    for (i, mk) in info.markerSamples.enumerated() {
        let t = Double(mk) / sr
        csv += "\(i + 1),\(String(format: "%.6f", t)),\(formatTime(t)),\(mk)\n"
    }
    try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
    print("  Markers CSV : \(csvURL.path)")

    // Text (human-readable)
    let txtURL = outputDir.appendingPathComponent("\(prefix)markers.txt")
    var txt = "# Markers exported from Behringer Wing/X-Live session\n"
    txt += "# Session: \(info.sessionName)\n"
    txt += "# Sample rate: \(info.sampleRate) Hz\n"
    txt += "#\n"
    txt += "# Marker\tTime\t\tSample\n"
    for (i, mk) in info.markerSamples.enumerated() {
        let t = Double(mk) / sr
        txt += "  \(i + 1)\t\t\(formatTime(t))\t\t\(mk)\n"
    }
    try? txt.write(to: txtURL, atomically: true, encoding: .utf8)
    print("  Markers TXT : \(txtURL.path)")
}
