// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

// Writes a little-endian UInt32 into a byte buffer at a given offset.
private func writeU32(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
    let le = value.littleEndian
    withUnsafeBytes(of: le) { buf.replaceSubrange(offset..<offset + 4, with: $0) }
}

final class SELogTests: XCTestCase {

    // Builds a 2048-byte SE_LOG.bin blob with the given field values.
    private func makeData(
        timestamp: UInt32 = 0x26050901,
        numChannels: UInt32 = 4,
        sampleRate: UInt32 = 48000,
        numTakes: UInt32 = 1,
        numMarkers: UInt32 = 0,
        totalLength: UInt32 = 0,
        takeSizes: [UInt32] = [480_000],
        markerSamples: [UInt32] = [],
        sessionName: String = ""
    ) -> Data {
        var buf = [UInt8](repeating: 0, count: 2048)
        writeU32(timestamp,   into: &buf, at: 0)
        writeU32(numChannels, into: &buf, at: 4)
        writeU32(sampleRate,  into: &buf, at: 8)
        writeU32(numTakes,    into: &buf, at: 16)
        writeU32(numMarkers,  into: &buf, at: 20)
        writeU32(totalLength, into: &buf, at: 24)
        for (i, sz) in takeSizes.prefix(256).enumerated() {
            writeU32(sz, into: &buf, at: 28 + i * 4)
        }
        for (i, mk) in markerSamples.prefix(100).enumerated() {
            writeU32(mk, into: &buf, at: 1052 + i * 4)
        }
        if !sessionName.isEmpty, let ascii = sessionName.data(using: .ascii) {
            let len = min(ascii.count, 15)
            buf.replaceSubrange(1553..<1553 + len, with: ascii.prefix(len))
            // buf[1553 + len] is already 0 (null terminator)
        }
        return Data(buf)
    }

    private func parse(_ data: Data) throws -> SessionInfo {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try parseSELog(at: tmp)
    }

    // MARK: - Errors

    func testFileNotFound() {
        XCTAssertThrowsError(try parseSELog(at: URL(fileURLWithPath: "/no/such/SE_LOG.bin"))) {
            guard case SELogError.fileNotFound = $0 else {
                XCTFail("Expected fileNotFound, got \($0)"); return
            }
        }
    }

    func testFileTooSmall() throws {
        XCTAssertThrowsError(try parse(Data(count: 27))) {
            guard case SELogError.fileTooSmall(let sz) = $0 else {
                XCTFail("Expected fileTooSmall, got \($0)"); return
            }
            XCTAssertEqual(sz, 27)
        }
    }

    func testMinimumSizeAccepted() throws {
        // 28 bytes is the minimum valid size; it gets padded to 2048 internally.
        XCTAssertNoThrow(try parse(Data(count: 28)))
    }

    // MARK: - Basic fields

    func testBasicFields() throws {
        let info = try parse(makeData(
            timestamp: 0x26050901,
            numChannels: 8,
            sampleRate: 96_000,
            numTakes: 2,
            numMarkers: 3,
            totalLength: 960_000
        ))
        XCTAssertEqual(info.timestamp, 0x26050901)
        XCTAssertEqual(info.numChannels, 8)
        XCTAssertEqual(info.sampleRate, 96_000)
        XCTAssertEqual(info.numTakes, 2)
        XCTAssertEqual(info.numMarkers, 3)
        XCTAssertEqual(info.totalLength, 960_000)
    }

    // MARK: - Take sizes

    func testTakeSizesRead() throws {
        let info = try parse(makeData(numTakes: 3, takeSizes: [100, 200, 300]))
        XCTAssertEqual(info.takeSizes, [100, 200, 300])
    }

    func testTakeSizesCappedAt256() throws {
        let sizes = [UInt32](repeating: 1, count: 300)
        let info = try parse(makeData(numTakes: 300, takeSizes: sizes))
        XCTAssertEqual(info.takeSizes.count, 256)
    }

    // MARK: - Markers

    func testMarkersRead() throws {
        let info = try parse(makeData(
            numMarkers: 3,
            markerSamples: [48_000, 96_000, 144_000]
        ))
        XCTAssertEqual(info.markerSamples, [48_000, 96_000, 144_000])
    }

    func testZeroMarkersFiltered() throws {
        // Wing writes 0 for unused marker slots; those must be dropped.
        let info = try parse(makeData(
            numMarkers: 3,
            markerSamples: [48_000, 0, 144_000]
        ))
        XCTAssertEqual(info.markerSamples, [48_000, 144_000])
    }

    func testMarkersCappedAt100() throws {
        let markers = [UInt32](1...120)
        let info = try parse(makeData(numMarkers: 120, markerSamples: markers))
        XCTAssertEqual(info.markerSamples.count, 100)
    }

    // MARK: - Session name

    func testSessionNamePresent() throws {
        let info = try parse(makeData(sessionName: "MY SESSION"))
        XCTAssertEqual(info.sessionName, "MY SESSION")
    }

    func testSessionNameNullTerminated() throws {
        // Name field is 16 bytes; the parser stops at the first null byte.
        let info = try parse(makeData(sessionName: "TAKE1"))
        XCTAssertEqual(info.sessionName, "TAKE1")
    }

    func testSessionNameEmptyFallsBackToTimestamp() throws {
        let info = try parse(makeData(timestamp: 0x26050901, sessionName: ""))
        XCTAssertEqual(info.sessionName, "26050901")
    }

    // MARK: - Duration

    func testTotalDuration() throws {
        let info = try parse(makeData(sampleRate: 48_000, totalLength: 480_000))
        XCTAssertEqual(info.totalDuration, 10.0, accuracy: 1e-9)
    }

    func testTotalDurationZeroSampleRate() throws {
        let info = try parse(makeData(sampleRate: 0, totalLength: 48_000))
        XCTAssertEqual(info.totalDuration, 0)
    }
}

// MARK: - Data helpers

final class DataHelpersTests: XCTestCase {

    func testU32LittleEndian() {
        let data = Data([0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(data.u32(at: 0), 1)
    }

    func testU32OutOfBoundsReturnsZero() {
        let data = Data([0xFF, 0xFF, 0xFF])
        XCTAssertEqual(data.u32(at: 0), 0)
    }

    func testAsciiStringNullTerminated() {
        let data = Data([0x41, 0x42, 0x00, 0x43]) // "AB\0C"
        XCTAssertEqual(data.asciiString(at: 0, maxLength: 4), "AB")
    }

    func testAsciiStringNoNull() {
        let data = Data([0x41, 0x42, 0x43]) // "ABC"
        XCTAssertEqual(data.asciiString(at: 0, maxLength: 3), "ABC")
    }

    func testAsciiStringOutOfBoundsReturnsEmpty() {
        let data = Data([0x41])
        XCTAssertEqual(data.asciiString(at: 5, maxLength: 4), "")
    }
}

// MARK: - Formatting

final class SELogFormattingTests: XCTestCase {

    func testFormatSamplesSmall() {
        XCTAssertEqual(formatSamples(999), "999")
    }

    func testFormatSamplesThousands() {
        XCTAssertEqual(formatSamples(48_000), "48\u{202F}000")
    }

    func testFormatSamplesMillions() {
        XCTAssertEqual(formatSamples(1_234_567), "1\u{202F}234\u{202F}567")
    }

    func testFormatTimeUnderOneHour() {
        XCTAssertEqual(formatTime(90.5), "01:30.500")
    }

    func testFormatTimeOverOneHour() {
        XCTAssertEqual(formatTime(3661.0), "01:01:01.000")
    }


}
