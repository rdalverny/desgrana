// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
import CWav
@testable import DesgranaCore

// Cross-check: our WAVReader must recover the same format fields and the same raw `data`
// bytes that dr_wav wrote, and must read back anything WAVWriter produces (incl. RF64).
// Mirror of WAVWriterCompareTests on the read side. See docs/WAVREADER.md.
final class WAVReaderTests: XCTestCase {

    private struct Format {
        let channels: Int, sampleRate: Int, bits: Int, isFloat: Bool
        var name: String { "\(channels)ch-\(bits)\(isFloat ? "f" : "i")" }
    }

    private let formats: [Format] = [
        Format(channels: 1, sampleRate: 48_000, bits: 16, isFloat: false),
        Format(channels: 1, sampleRate: 48_000, bits: 24, isFloat: false),
        Format(channels: 2, sampleRate: 48_000, bits: 32, isFloat: false),
        Format(channels: 1, sampleRate: 96_000, bits: 32, isFloat: true),
        Format(channels: 2, sampleRate: 48_000, bits: 64, isFloat: true)
    ]

    // dr_wav writes the fixture; WAVReader must read identical format + bytes.
    func testReadsDrWavFilesByteExact() throws {
        for f in formats {
            let raw = pattern(count: 1000 * f.channels * f.bits / 8)
            let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
            try writeViaDrWav(url, f, raw)

            let r = try WAVReader(url: url)
            XCTAssertEqual(r.format.channels, f.channels, "\(f.name) channels")
            XCTAssertEqual(r.format.sampleRate, f.sampleRate, "\(f.name) sampleRate")
            XCTAssertEqual(r.format.bitsPerSample, f.bits, "\(f.name) bits")
            XCTAssertEqual(r.format.isFloat, f.isFloat, "\(f.name) isFloat")
            XCTAssertEqual(Int(r.dataByteCount), raw.count, "\(f.name) data size")
            XCTAssertEqual(try readAll(url), raw, "\(f.name) data bytes")
        }
    }

    // Our own writer round-trips through our own reader.
    func testReadsWAVWriterFiles() throws {
        for f in formats {
            let raw = pattern(count: 500 * f.channels * f.bits / 8)
            let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
            let w = try WAVWriter(url: url, format: WAVFormat(channels: f.channels, sampleRate: f.sampleRate,
                                                             bitsPerSample: f.bits, isFloat: f.isFloat))
            try raw.withUnsafeBytes { try w.append($0) }
            try w.finalize()
            XCTAssertEqual(try readAll(url), raw, "\(f.name)")
        }
    }

    // RF64: force the writer over its threshold, then read the ds64-resolved data size.
    func testReadsRF64() throws {
        let raw = pattern(count: 2000 * 2 * 2)            // 2ch 16-bit
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 2, sampleRate: 48_000,
                                                          bitsPerSample: 16, isFloat: false))
        w.rf64Threshold = 100                            // anything over 100 bytes upgrades to RF64
        try raw.withUnsafeBytes { try w.append($0) }
        try w.finalize()

        let r = try WAVReader(url: url)
        XCTAssertEqual(Int(r.dataByteCount), raw.count, "RF64 data size from ds64")
        XCTAssertEqual(try readAll(url), raw, "RF64 data bytes")
    }

    // A take cut at the 4 GB limit: chop bytes off the end; the reader clamps to what's there.
    func testToleratesTruncatedData() throws {
        let raw = pattern(count: 1000 * 2)               // 1ch 16-bit, blockAlign 2
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        let w = try WAVWriter(url: url, format: WAVFormat(channels: 1, sampleRate: 48_000,
                                                          bitsPerSample: 16, isFloat: false))
        try raw.withUnsafeBytes { try w.append($0) }
        try w.finalize()

        let handle = try FileHandle(forUpdating: url)    // chop 8 bytes (4 frames) off the end
        let end = try handle.seekToEnd()
        try handle.truncate(atOffset: end - 8)
        try handle.close()

        let got = try readAll(url)
        XCTAssertEqual(got.count, raw.count - 8, "clamped to bytes present")
        XCTAssertEqual(got, Array(raw.prefix(raw.count - 8)), "prefix intact")
    }

    // WAVE_FORMAT_EXTENSIBLE: 24 valid bits in a 32-bit container, PCM subformat.
    func testParsesExtensible() throws {
        var fmt = Data()
        fmt.appendLE(UInt16(0xFFFE))                     // formatTag = EXTENSIBLE
        fmt.appendLE(UInt16(1))                          // channels
        fmt.appendLE(UInt32(48_000))                     // sampleRate
        fmt.appendLE(UInt32(48_000 * 4))                 // avgBytesPerSec
        fmt.appendLE(UInt16(4))                          // blockAlign (32-bit container)
        fmt.appendLE(UInt16(32))                         // bitsPerSample (container)
        fmt.appendLE(UInt16(22))                         // cbSize
        fmt.appendLE(UInt16(24))                         // validBitsPerSample
        fmt.appendLE(UInt32(4))                          // channelMask (FRONT_CENTER)
        fmt.appendLE(UInt16(1))                          // subFormat tag = PCM
        fmt.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
                                0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])   // GUID remainder

        let pcm: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        var body = Data("WAVE".utf8)
        body.append(contentsOf: "fmt ".utf8); body.appendLE(UInt32(40)); body.append(fmt)
        body.append(contentsOf: "data".utf8); body.appendLE(UInt32(pcm.count)); body.append(contentsOf: pcm)
        var file = Data("RIFF".utf8); file.appendLE(UInt32(body.count)); file.append(body)

        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try file.write(to: url)

        let r = try WAVReader(url: url)
        XCTAssertEqual(r.format.bitsPerSample, 32)
        XCTAssertEqual(r.format.validBitsPerSample, 24)
        XCTAssertEqual(r.format.channelMask, 4)
        XCTAssertFalse(r.format.isFloat)
        XCTAssertEqual(try readAll(url), pcm)
    }

    func testRejectsNonRIFF() throws {
        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try Data(pattern(count: 64)).write(to: url)
        XCTAssertThrowsError(try WAVReader(url: url)) {
            guard case WAVReaderError.notRIFF = $0 else { return XCTFail("expected notRIFF, got \($0)") }
        }
    }

    func testRejectsCompressedFormat() throws {
        var fmt = Data()
        fmt.appendLE(UInt16(2))                          // WAVE_FORMAT_ADPCM
        fmt.appendLE(UInt16(1)); fmt.appendLE(UInt32(48_000)); fmt.appendLE(UInt32(48_000))
        fmt.appendLE(UInt16(1)); fmt.appendLE(UInt16(8))
        var body = Data("WAVE".utf8)
        body.append(contentsOf: "fmt ".utf8); body.appendLE(UInt32(16)); body.append(fmt)
        body.append(contentsOf: "data".utf8); body.appendLE(UInt32(2)); body.append(contentsOf: [0, 0])
        var file = Data("RIFF".utf8); file.appendLE(UInt32(body.count)); file.append(body)

        let url = tmp(); defer { try? FileManager.default.removeItem(at: url) }
        try file.write(to: url)
        XCTAssertThrowsError(try WAVReader(url: url)) {
            guard case WAVReaderError.unsupportedFormat = $0 else { return XCTFail("expected unsupportedFormat, got \($0)") }
        }
    }

    // MARK: - Helpers

    private func readAll(_ url: URL) throws -> [UInt8] {
        let r = try WAVReader(url: url)
        defer { r.close() }
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096 * max(r.format.blockAlign, 1))
        while true {
            let n = try buf.withUnsafeMutableBytes { try r.read(into: $0) }
            if n == 0 { break }
            out.append(contentsOf: buf[0 ..< n])
        }
        return out
    }

    private func writeViaDrWav(_ url: URL, _ f: Format, _ raw: [UInt8]) throws {
        var fmt = drwav_data_format()
        fmt.container     = drwav_container_riff
        fmt.format        = UInt32(f.isFloat ? 3 : 1)
        fmt.channels      = UInt32(f.channels)
        fmt.sampleRate    = UInt32(f.sampleRate)
        fmt.bitsPerSample = UInt32(f.bits)
        let w = UnsafeMutablePointer<drwav>.allocate(capacity: 1)
        defer { w.deallocate() }
        guard url.path.withCString({ drwav_init_file_write(w, $0, &fmt, nil) }) == 1 else {
            throw Err.write(f.name)
        }
        _ = raw.withUnsafeBytes { drwav_write_raw(w, raw.count, $0.baseAddress) }
        drwav_uninit(w)
    }

    private enum Err: Error { case write(String) }
    private func pattern(count: Int) -> [UInt8] { (0..<count).map { UInt8(($0 * 7 + 3) & 0xFF) } }
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rd-\(UUID().uuidString).wav")
    }
}
