// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class BextTests: XCTestCase {
    // Field accessors on a raw bext payload.
    private func originator(_ d: Data) -> String { ascii(d, 256, 32) }
    private func origRef(_ d: Data) -> String { ascii(d, 288, 32) }
    private func date(_ d: Data) -> String { ascii(d, 320, 10) }
    private func time(_ d: Data) -> String { ascii(d, 330, 8) }
    private func timeRef(_ d: Data) -> UInt64 {
        let b = [UInt8](d)
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[338 + i]) }
        return v
    }
    private func coding(_ d: Data) -> String {
        String(bytes: [UInt8](d)[602...].prefix { $0 != 0 }, encoding: .ascii) ?? ""
    }
    private func ascii(_ d: Data, _ off: Int, _ len: Int) -> String {
        let b = [UInt8](d)[off ..< off + len].prefix { $0 != 0 }
        return String(bytes: b, encoding: .ascii) ?? ""
    }

    // No source bext: Desgrana originator, no fabricated timecode, coded reference.
    func testSynthesizedBext() {
        let d = bextPayload(source: nil, sampleRate: 48_000)
        XCTAssertGreaterThanOrEqual(d.count, 602)
        XCTAssertEqual(originator(d), "Desgrana")
        XCTAssertEqual(timeRef(d), 0)
        XCTAssertEqual(date(d), "")
        XCTAssertEqual(time(d), "")
        XCTAssertEqual(origRef(d), "")
        XCTAssertTrue(coding(d).contains("T=Desgrana"))
        XCTAssertTrue(coding(d).contains("F=48000"))
    }

    // A source bext is preserved: originator, reference, date, time, timecode and
    // its CodingHistory carry through; Desgrana appends its own history line.
    func testPreservesSourceBext() throws {
        let url = try writeWAVWithBext(
            originator: "Zoom F8", reference: "ZOOMF8-001", date: "2019-01-10", time: "20:18:24",
            timeRef: 3_508_992_000, history: "A=PCM,F=48000,W=24,M=stereo,T=Zoom F8")
        defer { try? FileManager.default.removeItem(at: url) }

        let src = try XCTUnwrap(parseSourceBext(at: url))
        XCTAssertEqual(src.originator, "Zoom F8")
        XCTAssertEqual(src.originatorReference, "ZOOMF8-001")
        XCTAssertEqual(src.originationDate, "2019-01-10")
        XCTAssertEqual(src.originationTime, "20:18:24")

        let d = bextPayload(source: src, sampleRate: 48_000)
        XCTAssertEqual(originator(d), "Zoom F8")          // source originator preserved
        XCTAssertEqual(origRef(d), "ZOOMF8-001")          // source reference preserved
        XCTAssertEqual(date(d), "2019-01-10")
        XCTAssertEqual(time(d), "20:18:24")
        XCTAssertEqual(timeRef(d), 3_508_992_000)         // timecode preserved
        XCTAssertTrue(coding(d).contains("T=Zoom F8"))    // source history preserved
        XCTAssertTrue(coding(d).contains("T=Desgrana"))   // our line appended after it
        let lines = coding(d).split(separator: "\r\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Zoom") && lines[1].contains("Desgrana"))
    }

    func testNoBextReturnsNil() throws {
        let url = try writeWAVWithBext(originator: nil, reference: "", date: "", time: "",
                                       timeRef: 0, history: "", includeBext: false)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(parseSourceBext(at: url))
    }

    // MARK: - Helper: minimal WAV with an optional bext chunk

    private func writeWAVWithBext(originator: String?, reference: String, date: String, time: String,
                                  timeRef: UInt64, history: String, includeBext: Bool = true) throws -> URL {
        func field(_ s: String, _ len: Int) -> [UInt8] {
            var b = Array(s.utf8.prefix(len)); b += Array(repeating: 0, count: len - b.count); return b
        }
        func le32(_ v: UInt32) -> [UInt8] { [0, 8, 16, 24].map { UInt8((v >> $0) & 0xFF) } }

        var bext: [UInt8] = []
        bext += field("", 256)                       // Description
        bext += field(originator ?? "", 32)          // Originator
        bext += field(reference, 32)                 // OriginatorReference
        bext += field(date, 10)
        bext += field(time, 8)
        bext += le32(UInt32(timeRef & 0xFFFF_FFFF))  // TimeReference low
        bext += le32(UInt32(timeRef >> 32))          // TimeReference high
        bext += [1, 0]                               // version
        bext += Array(repeating: 0, count: 64 + 10 + 180)
        bext += Array(history.utf8)                  // CodingHistory

        func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
            var c = Array(id.utf8) + le32(UInt32(body.count)) + body
            if body.count % 2 == 1 { c.append(0) }
            return c
        }
        // PCM fmt: format=1, channels=1, sampleRate=48000, byteRate, blockAlign=2, bits=16
        let fmtBody: [UInt8] = [1, 0, 1, 0] + le32(48_000) + le32(96_000) + [2, 0, 16, 0]
        var body: [UInt8] = Array("WAVE".utf8) + chunk("fmt ", fmtBody)
        if includeBext { body += chunk("bext", bext) }
        body += chunk("data", [0, 0, 0, 0])
        let riff = Array("RIFF".utf8) + le32(UInt32(body.count)) + body

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bext-test-\(UUID().uuidString).wav")
        try Data(riff).write(to: url)
        return url
    }
}
