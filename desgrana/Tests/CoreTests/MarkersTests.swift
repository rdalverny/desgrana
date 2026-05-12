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

/// Builds a minimal 44-byte WAV (no audio samples).
/// Default RIFF size = 36 (correct for this layout); override for edge-case tests.
private func makeMinimalWAV(riffSize: UInt32 = 36) -> Data {
    var wav = Data()
    func le32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
    func le16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
    wav.append(contentsOf: "RIFF".utf8); le32(riffSize)
    wav.append(contentsOf: "WAVE".utf8)
    wav.append(contentsOf: "fmt ".utf8); le32(16)
    le16(1); le16(1)              // PCM, mono
    le32(48_000); le32(96_000)   // sampleRate, byteRate
    le16(2); le16(16)             // blockAlign, bitsPerSample
    wav.append(contentsOf: "data".utf8); le32(0)
    return wav  // 44 bytes
}

private func writeTempWAV(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".wav")
    try data.write(to: url)
    return url
}

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

// MARK: - cue chunk

final class CueChunkTests: XCTestCase {

    func testCueChunkWritten() throws {
        // 1 marker → cue chunk = 8-byte header + 4 (count) + 1×24 = 36 bytes
        let url = try writeTempWAV(makeMinimalWAV())
        defer { try? FileManager.default.removeItem(at: url) }

        writeCueChunks(to: [url], markers: [48_000])

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44 + 36)
        XCTAssertEqual(bytes[44..<48], Data("cue ".utf8))   // chunk id
        XCTAssertEqual(u32LE(bytes, at: 48), 28)            // chunkDataSize = 4 + 1×24
        XCTAssertEqual(u32LE(bytes, at: 52), 1)             // count = 1
        XCTAssertEqual(u32LE(bytes, at: 56), 1)             // entry id = 1
        XCTAssertEqual(u32LE(bytes, at: 60), 48_000)        // position
        XCTAssertEqual(bytes[64..<68], Data("data".utf8))   // data fourCC
        XCTAssertEqual(u32LE(bytes, at: 68), 0)             // chunkStart
        XCTAssertEqual(u32LE(bytes, at: 72), 0)             // blockStart
        XCTAssertEqual(u32LE(bytes, at: 76), 48_000)        // sampleOffset
        XCTAssertEqual(u32LE(bytes, at: 4), 36 + 36)        // RIFF size updated
    }

    func testCueChunkTwoMarkers() throws {
        // 2 markers → chunk = 8 + 4 + 2×24 = 60 bytes
        let url = try writeTempWAV(makeMinimalWAV())
        defer { try? FileManager.default.removeItem(at: url) }

        writeCueChunks(to: [url], markers: [1_000, 2_000])

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44 + 60)
        XCTAssertEqual(u32LE(bytes, at: 52), 2)      // count
        XCTAssertEqual(u32LE(bytes, at: 56), 1)      // id[0]
        XCTAssertEqual(u32LE(bytes, at: 60), 1_000)  // position[0]
        XCTAssertEqual(u32LE(bytes, at: 76), 1_000)  // sampleOffset[0]
        XCTAssertEqual(u32LE(bytes, at: 80), 2)      // id[1]
        XCTAssertEqual(u32LE(bytes, at: 84), 2_000)  // position[1]
        XCTAssertEqual(u32LE(bytes, at: 100), 2_000) // sampleOffset[1]
        XCTAssertEqual(u32LE(bytes, at: 4), 36 + 60) // RIFF size updated
    }

    func testCueChunkEmptySkipped() throws {
        let url = try writeTempWAV(makeMinimalWAV())
        defer { try? FileManager.default.removeItem(at: url) }

        writeCueChunks(to: [url], markers: [])

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44)     // file unchanged
        XCTAssertEqual(u32LE(bytes, at: 4), 36) // RIFF size unchanged
    }

    func testCueChunkRIFF64Untouched() throws {
        // 0xFFFFFFFF marks a >4 GB RIFF64 file; size field must not be overwritten.
        let url = try writeTempWAV(makeMinimalWAV(riffSize: 0xFFFF_FFFF))
        defer { try? FileManager.default.removeItem(at: url) }

        writeCueChunks(to: [url], markers: [1_000])

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44 + 36)                // chunk was appended
        XCTAssertEqual(u32LE(bytes, at: 4), 0xFFFF_FFFF)   // size field untouched
    }

    func testCueChunkOverflowGuard() throws {
        // riffSize + chunk(36) > 0xFFFFFFFE → overflow guard must leave size field untouched.
        // 0xFFFFFFDF + 36 = 0x100000003, overflows UInt32.
        let url = try writeTempWAV(makeMinimalWAV(riffSize: 0xFFFF_FFDF))
        defer { try? FileManager.default.removeItem(at: url) }

        writeCueChunks(to: [url], markers: [1_000])

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, 44 + 36)                // chunk was appended
        XCTAssertEqual(u32LE(bytes, at: 4), 0xFFFF_FFDF)   // size field untouched
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
