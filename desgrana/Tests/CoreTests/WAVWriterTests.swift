// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class WAVWriterTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wavw-\(UUID().uuidString).wav")
    }

    private func offset(of id: String, in d: Data) -> Int? {
        d.range(of: Data(id.utf8))?.lowerBound
    }

    // A plain PCM file round-trips through our own readers, with the right format and duration.
    func testPlainPCMRoundTrip() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 48_000,
                                                          bitsPerSample: 16, isFloat: false))
        try w.append(Data(count: 480 * 2))      // 480 frames of silence, 16-bit mono
        try w.finalize()

        let info = try XCTUnwrap(probeWavHeader(at: url))
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 48_000)
        XCTAssertEqual(info.duration, 480.0 / 48_000, accuracy: 1e-9)
    }

    // Metadata chunks are written before `data`, in order, and read back intact.
    func testMetadataBeforeData() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let bext = Data("BEXT-PAYLOAD".utf8)
        let ixml = Data("<iXML/>".utf8)
        let cue  = Data("CUEDATA".utf8)
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 48_000,
                                                          bitsPerSample: 16, isFloat: false),
                              metadata: [("bext", bext), ("iXML", ixml), ("cue ", cue)])
        try w.append(Data(count: 8))
        try w.finalize()

        let d = try Data(contentsOf: url)
        let dataOff = try XCTUnwrap(offset(of: "data", in: d))
        for id in ["bext", "iXML", "cue "] {
            let off = try XCTUnwrap(offset(of: id, in: d), "\(id) missing")
            XCTAssertLessThan(off, dataOff, "\(id) must precede data")
        }
        XCTAssertEqual(riffChunk(at: url, id: "bext"), bext)
        XCTAssertEqual(riffChunk(at: url, id: "iXML"), ixml)
        XCTAssertEqual(riffChunk(at: url, id: "cue "), cue)
    }

    // The data payload is byte-exact: what we append is what we read back.
    func testDataIsByteExact() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let samples = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 48_000,
                                                          bitsPerSample: 16, isFloat: false))
        try w.append(samples)
        try w.finalize()
        XCTAssertEqual(riffChunk(at: url, id: "data"), samples)
    }

    // Float output carries a fact chunk before data with the right sample count.
    func testFloatHasFactChunk() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 48_000,
                                                          bitsPerSample: 32, isFloat: true))
        try w.append(Data(count: 100 * 4))      // 100 float32 frames
        try w.finalize()

        let d = try Data(contentsOf: url)
        let factOff = try XCTUnwrap(offset(of: "fact", in: d))
        XCTAssertLessThan(factOff, try XCTUnwrap(offset(of: "data", in: d)))
        let fact = try XCTUnwrap(riffChunk(at: url, id: "fact"))
        let sampleCount = UInt32(fact[0]) | UInt32(fact[1]) << 8 | UInt32(fact[2]) << 16 | UInt32(fact[3]) << 24
        XCTAssertEqual(sampleCount, 100)
    }

    // Odd-length payloads pad to even; the next chunk and EOF stay aligned.
    func testOddDataIsPadded() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 8_000,
                                                          bitsPerSample: 8, isFloat: false))
        try w.append(Data(count: 3))            // odd
        try w.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual(d.count % 2, 0)
        // data size field still reports the unpadded length (3).
        let off = try XCTUnwrap(offset(of: "data", in: d)) + 4
        let size = UInt32(d[off]) | UInt32(d[off + 1]) << 8 | UInt32(d[off + 2]) << 16 | UInt32(d[off + 3]) << 24
        XCTAssertEqual(size, 3)
    }

    // RF64 path: forced via a low threshold so we don't write 4 GB. The reserved JUNK
    // becomes ds64, the form id flips to RF64, and the real size lives in ds64.
    func testRF64Upgrade() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 48_000,
                                                          bitsPerSample: 16, isFloat: false))
        w.rf64Threshold = 50                    // any real data tips it over
        try w.append(Data(count: 200))          // 100 frames, 16-bit mono
        try w.finalize()

        let d = try Data(contentsOf: url)
        XCTAssertEqual([UInt8](d[0..<4]), Array("RF64".utf8))
        XCTAssertEqual([UInt8](d[4..<8]), [0xFF, 0xFF, 0xFF, 0xFF])   // RIFF size sentinel
        XCTAssertEqual(offset(of: "ds64", in: d), 12)                 // JUNK upgraded in place
        XCTAssertNil(offset(of: "JUNK", in: d))

        // ds64 dataSize (body offset 20 + 8) holds the real size; readers use it.
        let ds = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(d[28 + $1]) << (8 * $1)) }
        XCTAssertEqual(ds, 200)

        // probeWavHeader reads the real data size from ds64 (not the sentinel) → right duration.
        let info = try XCTUnwrap(probeWavHeader(at: url))
        XCTAssertEqual(info.duration, 100.0 / 48_000, accuracy: 1e-9)
    }
}
