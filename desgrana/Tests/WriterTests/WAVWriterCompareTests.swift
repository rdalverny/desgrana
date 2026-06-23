// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
import CWav
@testable import DesgranaCore
#if canImport(AudioToolbox)
import AudioToolbox
#endif

// Cross-check: a file written by our WAVWriter must be decoded by dr_wav exactly
// like the equivalent file written by dr_wav itself — same format fields and the
// same raw `data` bytes. This is the parallel comparison before wiring WAVWriter
// into the splitters.
final class WAVWriterCompareTests: XCTestCase {

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

    func testWAVWriterMatchesReferenceDecoders() throws {
        for f in formats {
            let frames = 1000
            let raw = pattern(count: frames * f.channels * f.bits / 8)

            let viaLib = tmp(); defer { try? FileManager.default.removeItem(at: viaLib) }
            let viaOurs = tmp(); defer { try? FileManager.default.removeItem(at: viaOurs) }

            try writeViaDrWav(viaLib, f, raw)
            try writeViaWAVWriter(viaOurs, f, raw)

            let a = try XCTUnwrap(readViaDrWav(viaLib), "\(f.name): dr_wav file unreadable")
            let b = try XCTUnwrap(readViaDrWav(viaOurs), "\(f.name): WAVWriter file unreadable by dr_wav")

            XCTAssertEqual(a.channels, b.channels, "\(f.name) channels")
            XCTAssertEqual(a.sampleRate, b.sampleRate, "\(f.name) sampleRate")
            XCTAssertEqual(a.bits, b.bits, "\(f.name) bits")
            XCTAssertEqual(a.formatTag, b.formatTag, "\(f.name) formatTag")
            XCTAssertEqual(a.frames, b.frames, "\(f.name) frame count")
            XCTAssertEqual(a.data, b.data, "\(f.name) data bytes (lib vs ours)")
            XCTAssertEqual(b.data, raw, "\(f.name) WAVWriter data must equal source bytes")

            // Second reference decoder: ExtAudioFile (macOS) must read our file too.
            #if canImport(AudioToolbox)
            let viaAT = try XCTUnwrap(readViaExtAudioFile(viaOurs),
                                      "\(f.name): WAVWriter file unreadable by ExtAudioFile")
            XCTAssertEqual(viaAT, raw, "\(f.name) ExtAudioFile data must equal source bytes")
            #endif
        }
    }

    #if canImport(AudioToolbox)
    // Reads the raw `data` bytes back via ExtAudioFile (client format = file format).
    private func readViaExtAudioFile(_ url: URL) -> [UInt8]? {
        var file: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let ef = file else { return nil }
        defer { ExtAudioFileDispose(ef) }
        var fmt = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileDataFormat, &sz, &fmt) == noErr,
              ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat, sz, &fmt) == noErr,
              fmt.mBytesPerFrame > 0 else { return nil }

        let bytesPerFrame = Int(fmt.mBytesPerFrame)
        let blockFrames = 4096
        var out = [UInt8]()
        var block = [UInt8](repeating: 0, count: blockFrames * bytesPerFrame)
        while true {
            var frames = UInt32(blockFrames)
            var status = noErr
            block.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: fmt.mChannelsPerFrame,
                                          mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                status = ExtAudioFileRead(ef, &frames, &abl)
                if status == noErr && frames > 0 {
                    out.append(contentsOf: raw.prefix(Int(frames) * bytesPerFrame))
                }
            }
            guard status == noErr else { return nil }
            if frames == 0 { break }
        }
        return out
    }
    #endif

    // MARK: - dr_wav write / read

    private func writeViaDrWav(_ url: URL, _ f: Format, _ raw: [UInt8]) throws {
        var fmt = drwav_data_format()
        fmt.container     = drwav_container_riff
        fmt.format        = UInt32(f.isFloat ? 3 : 1)        // 3=IEEE float, 1=PCM
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

    private struct Decoded: Equatable {
        let channels: UInt16, sampleRate: UInt32, bits: UInt16, formatTag: UInt16
        let frames: UInt64, data: [UInt8]
    }

    private func readViaDrWav(_ url: URL) -> Decoded? {
        let r = UnsafeMutablePointer<drwav>.allocate(capacity: 1)
        guard url.path.withCString({ drwav_init_file(r, $0, nil) }) == 1 else { r.deallocate(); return nil }
        defer { drwav_uninit(r); r.deallocate() }
        let n = Int(r.pointee.dataChunkDataSize)
        var buf = [UInt8](repeating: 0, count: n)
        let read = buf.withUnsafeMutableBytes { drwav_read_raw(r, n, $0.baseAddress) }
        return Decoded(channels: r.pointee.channels, sampleRate: r.pointee.sampleRate,
                       bits: r.pointee.bitsPerSample, formatTag: r.pointee.translatedFormatTag,
                       frames: r.pointee.totalPCMFrameCount, data: Array(buf[0..<read]))
    }

    // MARK: - WAVWriter write

    private func writeViaWAVWriter(_ url: URL, _ f: Format, _ raw: [UInt8]) throws {
        let w = try WAVWriter(url: url, format: WAVFormat(channels: f.channels, sampleRate: f.sampleRate,
                                                          bitsPerSample: f.bits, isFloat: f.isFloat))
        try raw.withUnsafeBytes { try w.append($0) }
        try w.finalize()
    }

    // MARK: - Helpers

    private enum Err: Error { case write(String) }

    private func pattern(count: Int) -> [UInt8] { (0..<count).map { UInt8(($0 * 7 + 3) & 0xFF) } }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmp-\(UUID().uuidString).wav")
    }
}
