// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class RF64Tests: XCTestCase {
    // probeWavHeader reads the real >4 GB data size from ds64, not the 0xFFFFFFFF sentinel.
    func testProbeReadsDs64DataSize() throws {
        let declared: UInt64 = 5_000_000_000          // ~4.66 GB, beyond the 32-bit limit
        let url = try makeRF64(dataDeclared: declared, dataBytes: 0)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try XCTUnwrap(probeWavHeader(at: url))
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.sampleRate, 48_000)
        // duration = declared / (channels * bytesPerSample) / sampleRate
        XCTAssertEqual(info.duration, Double(declared) / 2 / 48_000, accuracy: 0.001)
    }

    // appendRIFFChunk grows the ds64 riffSize (not the 0xFFFFFFFF sentinel at offset 4),
    // and the appended chunk stays reachable.
    func testAppendUpdatesDs64RiffSize() throws {
        let url = try makeRF64(dataDeclared: 8, dataBytes: 8, riffSize: 1000)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = Data("hello".utf8)              // 5 bytes → chunk = 8 + 6 (padded) = 14
        XCTAssertTrue(appendRIFFChunk(to: url, id: "iXML", payload: payload))

        // ds64 riffSize (file offset 20) grew by the chunk's byte count.
        let d = try Data(contentsOf: url)
        let riffSize = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(d[20 + $1]) << (8 * $1)) }
        XCTAssertEqual(riffSize, 1000 + 14)

        // offset 4 still holds the RF64 sentinel (untouched, not corrupted).
        XCTAssertEqual([UInt8](d[4..<8]), [0xFF, 0xFF, 0xFF, 0xFF])

        // The appended chunk is findable (data declared small, so reachable).
        XCTAssertEqual(riffChunk(at: url, id: "iXML"), payload)
    }

    // MARK: - Helper: minimal RF64 file

    private func makeRF64(dataDeclared: UInt64, dataBytes: Int, riffSize: UInt64 = 0,
                          sampleRate: UInt32 = 48_000, channels: UInt16 = 1,
                          bits: UInt16 = 16) throws -> URL {
        func le16(_ v: UInt16) -> [UInt8] { [0, 8].map { UInt8((v >> $0) & 0xFF) } }
        func le32(_ v: UInt32) -> [UInt8] { [0, 8, 16, 24].map { UInt8((v >> $0) & 0xFF) } }
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            var c = Array(id.utf8) + le32(UInt32(body.count)) + body
            if body.count % 2 == 1 { c.append(0) }
            return c
        }

        let ds64 = chunk("ds64", le64(riffSize) + le64(dataDeclared) + le64(0) + le32(0))
        let blockAlign = UInt16(Int(channels) * Int(bits) / 8)
        let fmt = chunk("fmt ", le16(1) + le16(channels) + le32(sampleRate)
                        + le32(sampleRate * UInt32(blockAlign)) + le16(blockAlign) + le16(bits))
        // data: 0xFFFFFFFF size sentinel + a few real bytes
        let data = Array("data".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array(repeating: UInt8(0), count: dataBytes)

        var bytes = Array("RF64".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WAVE".utf8)
        bytes += ds64 + fmt + data

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rf64-test-\(UUID().uuidString).wav")
        try Data(bytes).write(to: url)
        return url
    }
}
