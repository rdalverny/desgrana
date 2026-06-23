// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

// MARK: - Byte helpers

private func u32LE(_ data: Data, at offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

private func u32BE(_ data: Data, at offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset]) << 24
        | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8
        | UInt32(data[offset + 3])
}

private func u16BE(_ data: Data, at offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

// MARK: - Fixture builders

/// Builds a SessionInfo via parseSELog from the given marker list and sample rate.
private func makeSessionInfo(markerSamples: [UInt32], sampleRate: UInt32 = 48_000) throws -> SessionInfo {
    var buf = [UInt8](repeating: 0, count: 2048)
    func writeU32(_ v: UInt32, at offset: Int) {
        let le = v.littleEndian
        withUnsafeBytes(of: le) { buf.replaceSubrange(offset..<offset + 4, with: $0) }
    }
    writeU32(sampleRate, at: 8)
    writeU32(UInt32(markerSamples.count), at: 20)
    for (i, mk) in markerSamples.prefix(100).enumerated() { writeU32(mk, at: 1052 + i * 4) }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
    try Data(buf).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    return try parseSELog(at: tmp)
}

/// Runs exportMIDIMarkers and returns the bytes of the produced markers.mid.
private func smfBytes(markerSamples: [UInt32], sampleRate: UInt32 = 48_000) throws -> Data {
    let info = try makeSessionInfo(markerSamples: markerSamples, sampleRate: sampleRate)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    exportMIDIMarkers(info, to: dir, prefix: "")
    return try Data(contentsOf: dir.appendingPathComponent("markers.mid"))
}

// MARK: - cue payload

final class CuePayloadTests: XCTestCase {

    func testSingleMarker() {
        // 1 marker → payload = count(4) + 1×24 = 28 bytes
        let p = cuePayload([48_000])
        XCTAssertEqual(p.count, 28)
        XCTAssertEqual(u32LE(p, at: 0), 1)             // count
        XCTAssertEqual(u32LE(p, at: 4), 1)             // entry id
        XCTAssertEqual(u32LE(p, at: 8), 48_000)        // position
        XCTAssertEqual(p[12..<16], Data("data".utf8))  // data fourCC
        XCTAssertEqual(u32LE(p, at: 16), 0)            // chunkStart
        XCTAssertEqual(u32LE(p, at: 20), 0)            // blockStart
        XCTAssertEqual(u32LE(p, at: 24), 48_000)       // sampleOffset
    }

    func testTwoMarkers() {
        // 2 markers → payload = count(4) + 2×24 = 52 bytes
        let p = cuePayload([1_000, 2_000])
        XCTAssertEqual(p.count, 52)
        XCTAssertEqual(u32LE(p, at: 0), 2)       // count
        XCTAssertEqual(u32LE(p, at: 4), 1)       // id[0]
        XCTAssertEqual(u32LE(p, at: 8), 1_000)   // position[0]
        XCTAssertEqual(u32LE(p, at: 24), 1_000)  // sampleOffset[0]
        XCTAssertEqual(u32LE(p, at: 28), 2)      // id[1]
        XCTAssertEqual(u32LE(p, at: 32), 2_000)  // position[1]
        XCTAssertEqual(u32LE(p, at: 48), 2_000)  // sampleOffset[1]
    }

    func testEmpty() {
        let p = cuePayload([])
        XCTAssertEqual(p.count, 4)         // count(4) only
        XCTAssertEqual(u32LE(p, at: 0), 0) // count = 0
    }
}

// MARK: - SMF markers

final class SMFMarkersTests: XCTestCase {

    func testSMFHeader() throws {
        let bytes = try smfBytes(markerSamples: [48_000])
        XCTAssertEqual(bytes[0..<4], Data("MThd".utf8))
        XCTAssertEqual(u32BE(bytes, at: 4), 6)   // chunk length always 6
        XCTAssertEqual(u16BE(bytes, at: 8), 0)   // format 0 (single track)
        XCTAssertEqual(u16BE(bytes, at: 10), 1)  // 1 track
        XCTAssertEqual(bytes[12], 0xE7)          // SMPTE −25 fps
        XCTAssertEqual(bytes[13], 0x28)          // 40 ticks/frame → 1000 ticks/s
    }

    func testSMFTrackName() throws {
        let bytes = try smfBytes(markerSamples: [48_000])
        // MTrk body starts at offset 22 (14-byte MThd + 8-byte MTrk header)
        let body = bytes.dropFirst(22)
        let expected: [UInt8] = [0x00, 0xFF, 0x03, 0x07] + Array("Markers".utf8)
        XCTAssertEqual(Array(body.prefix(expected.count)), expected)
    }

    func testSMFSingleMarkerTick() throws {
        // 48000 samples @ 48000 Hz = 1 s = 1000 ticks; VarLen(1000) = [0x87, 0x68]
        let bytes = try smfBytes(markerSamples: [48_000])
        let body = Array(bytes.dropFirst(22))
        // track name event = 4-byte prefix + 7 bytes "Markers" = 11 bytes
        let markerStart = 11
        let expected: [UInt8] = [0x87, 0x68, 0xFF, 0x06, 0x08] + Array("Marker 1".utf8)
        XCTAssertEqual(Array(body[markerStart..<markerStart + expected.count]), expected)
    }

    func testSMFDeltaTime() throws {
        // Two markers at 48000 and 96000: delta1 = 1000, delta2 = 2000−1000 = 1000
        // Both encode as VarLen(1000) = [0x87, 0x68]
        let bytes = try smfBytes(markerSamples: [48_000, 96_000])
        let body = Array(bytes.dropFirst(22))
        // marker 1 event: delta(2) + [0xFF,0x06](2) + len(1) + "Marker 1"(8) = 13 bytes
        let marker2Start = 11 + 13
        XCTAssertEqual(body[marker2Start], 0x87)
        XCTAssertEqual(body[marker2Start + 1], 0x68)
    }

    func testSMFEndOfTrack() throws {
        let bytes = try smfBytes(markerSamples: [48_000])
        XCTAssertTrue(bytes.suffix(4).elementsEqual([0x00, 0xFF, 0x2F, 0x00]))
    }

    func testSMFEmptyMarkersNoFile() throws {
        let info = try makeSessionInfo(markerSamples: [])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        exportMIDIMarkers(info, to: dir, prefix: "")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.isEmpty)
    }
}
