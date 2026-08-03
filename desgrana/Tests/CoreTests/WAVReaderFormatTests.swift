// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class WAVReaderFormatTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wavr-\(UUID().uuidString).wav")
    }

    /// Builds a minimal RIFF/WAVE header with the given channel count and an empty
    /// `data` chunk. Enough for `WAVReader` to parse the format and reject or accept it.
    private func minimalWAV(channels: UInt16, bits: UInt16 = 16) -> Data {
        var fmt = Data()
        func le16(into d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le32(into d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        let blockAlign = channels &* (bits / 8)
        le16(into: &fmt, 1)                 // formatTag = PCM
        le16(into: &fmt, channels)
        le32(into: &fmt, 48_000)            // sample rate
        le32(into: &fmt, 0)                 // byte rate (unused by the reader)
        le16(into: &fmt, blockAlign)
        le16(into: &fmt, bits)

        var out = Data()
        func fourcc(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { le32(into: &out, v) }

        fourcc("RIFF"); u32(UInt32(4 + 8 + fmt.count + 8)); fourcc("WAVE")
        fourcc("fmt "); u32(UInt32(fmt.count)); out.append(fmt)
        fourcc("data"); u32(0)
        return out
    }

    /// A channel count past the cap is a malformed/hostile header, not a real capture.
    func testChannelCountAboveCapIsRejected() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try minimalWAV(channels: 9_999).write(to: url)

        XCTAssertThrowsError(try WAVReader(url: url)) { error in
            guard case WAVReaderError.unsupportedFormat = error else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
        }
    }

    /// The cap itself is a legal count and must still parse.
    func testChannelCountAtCapIsAccepted() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try minimalWAV(channels: UInt16(Constants.Format.maxChannels)).write(to: url)

        XCTAssertNoThrow(try WAVReader(url: url))
    }
}
