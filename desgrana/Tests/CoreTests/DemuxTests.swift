// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class DemuxTests: XCTestCase {
    private func mono(_ input: [UInt8], bytesPerSample: Int, isFloat: Bool) -> Bool {
        var inp = input
        var out = [UInt8](repeating: 0, count: input.count)
        var hasSignal = false
        inp.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                demuxMono(from: i.baseAddress!, to: o.baseAddress!, frames: input.count / bytesPerSample,
                          numChannels: 1, ch: 0, bytesPerSample: bytesPerSample, isFloat: isFloat,
                          hasSignal: &hasSignal)
            }
        }
        XCTAssertEqual(out, input, "samples must be copied verbatim")
        return hasSignal
    }

    // 0x80000000: full-scale negative as int32 → signal; -0.0 as float32 → silence.
    func testInt32FullScaleNegativeIsSignal() {
        XCTAssertTrue(mono([0x00, 0x00, 0x00, 0x80], bytesPerSample: 4, isFloat: false))
    }

    func testFloatNegativeZeroIsSilence() {
        XCTAssertFalse(mono([0x00, 0x00, 0x00, 0x80], bytesPerSample: 4, isFloat: true))
    }

    func testFloatPositiveZeroIsSilence() {
        XCTAssertFalse(mono([0x00, 0x00, 0x00, 0x00], bytesPerSample: 4, isFloat: true))
    }

    // A normal non-zero float sample (1.0f = 0x3F800000) is signal.
    func testFloatNonZeroIsSignal() {
        XCTAssertTrue(mono([0x00, 0x00, 0x80, 0x3F], bytesPerSample: 4, isFloat: true))
    }

    func testInt32ZeroIsSilence() {
        XCTAssertFalse(mono([0x00, 0x00, 0x00, 0x00], bytesPerSample: 4, isFloat: false))
    }

    // float64 -0.0 (0x8000000000000000) is silence; full-scale int64 negative is signal.
    func testFloat64NegativeZeroIsSilence() {
        XCTAssertFalse(mono([0, 0, 0, 0, 0, 0, 0, 0x80], bytesPerSample: 8, isFloat: true))
    }

    func testInt64FullScaleNegativeIsSignal() {
        XCTAssertTrue(mono([0, 0, 0, 0, 0, 0, 0, 0x80], bytesPerSample: 8, isFloat: false))
    }

    // 1.0 double = 0x3FF0000000000000 → non-zero, signal.
    func testFloat64NonZeroIsSignal() {
        XCTAssertTrue(mono([0, 0, 0, 0, 0, 0, 0xF0, 0x3F], bytesPerSample: 8, isFloat: true))
    }

    func testFloat64PositiveZeroIsSilence() {
        XCTAssertFalse(mono([0, 0, 0, 0, 0, 0, 0, 0], bytesPerSample: 8, isFloat: true))
    }

    // MARK: - Interleaved sources
    //
    // The cases above all run with numChannels == 1, which never exercises the
    // source stride. These build a real interleaved buffer where every byte
    // position holds a distinct value, so a wrong stride or channel offset
    // yields a mismatch instead of accidentally matching.

    private static let testFrames = 8
    private static let testChannels = 4

    /// Interleaved fixture: byte at (frame, channel, byteIndex) is unique and never zero,
    /// so silence detection cannot pass by accident.
    private func interleaved(frames: Int, channels: Int, bytesPerSample: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: frames * channels * bytesPerSample)
        for f in 0 ..< frames {
            for ch in 0 ..< channels {
                for b in 0 ..< bytesPerSample {
                    buf[(f * channels + ch) * bytesPerSample + b] = UInt8(1 + (f * 37 + ch * 11 + b) % 250)
                }
            }
        }
        return buf
    }

    /// Reference extraction, written independently of the implementation under test.
    private func expectedMono(from buf: [UInt8], frames: Int, channels: Int,
                              ch: Int, bytesPerSample: Int) -> [UInt8] {
        var out: [UInt8] = []
        for f in 0 ..< frames {
            let off = (f * channels + ch) * bytesPerSample
            out.append(contentsOf: buf[off ..< off + bytesPerSample])
        }
        return out
    }

    private func runMono(_ buf: [UInt8], frames: Int, channels: Int, ch: Int,
                         bytesPerSample: Int, isFloat: Bool,
                         hasSignal: inout Bool) -> [UInt8] {
        var input = buf
        var out = [UInt8](repeating: 0, count: frames * bytesPerSample)
        var signal = hasSignal
        input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                demuxMono(from: i.baseAddress!, to: o.baseAddress!, frames: frames,
                          numChannels: channels, ch: ch, bytesPerSample: bytesPerSample,
                          isFloat: isFloat, hasSignal: &signal)
            }
        }
        hasSignal = signal
        return out
    }

    private func runStereo(_ buf: [UInt8], frames: Int, channels: Int, left: Int, right: Int,
                           bytesPerSample: Int, isFloat: Bool,
                           hasSignal: inout Bool) -> [UInt8] {
        var input = buf
        var out = [UInt8](repeating: 0, count: frames * bytesPerSample * 2)
        var signal = hasSignal
        input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                demuxStereo(from: i.baseAddress!, to: o.baseAddress!, frames: frames,
                            numChannels: channels, left: left, right: right,
                            bytesPerSample: bytesPerSample, isFloat: isFloat, hasSignal: &signal)
            }
        }
        hasSignal = signal
        return out
    }

    /// Every channel of an interleaved buffer must come out byte-exact, at every bit depth.
    /// 3 bytes covers the byte-by-byte branch; 2/4/8 cover the typed-pointer branches.
    func testInterleavedExtractionIsByteExactAtEveryDepth() {
        let frames = Self.testFrames, channels = Self.testChannels
        for bps in [2, 3, 4, 8] {
            let buf = interleaved(frames: frames, channels: channels, bytesPerSample: bps)
            for ch in 0 ..< channels {
                var signal = false
                let got = runMono(buf, frames: frames, channels: channels, ch: ch,
                                  bytesPerSample: bps, isFloat: false, hasSignal: &signal)
                let want = expectedMono(from: buf, frames: frames, channels: channels,
                                        ch: ch, bytesPerSample: bps)
                XCTAssertEqual(got, want, "bytesPerSample=\(bps) channel=\(ch)")
                XCTAssertTrue(signal, "non-zero data must be signal (bps=\(bps) ch=\(ch))")
            }
        }
    }

    func testInt24InterleavedAllZeroIsSilence() {
        let frames = Self.testFrames, channels = Self.testChannels, bps = 3
        let buf = [UInt8](repeating: 0, count: frames * channels * bps)
        var signal = false
        let got = runMono(buf, frames: frames, channels: channels, ch: 2,
                          bytesPerSample: bps, isFloat: false, hasSignal: &signal)
        XCTAssertEqual(got, [UInt8](repeating: 0, count: frames * bps))
        XCTAssertFalse(signal)
    }

    func testInt16InterleavedAllZeroIsSilence() {
        let frames = Self.testFrames, channels = Self.testChannels, bps = 2
        let buf = [UInt8](repeating: 0, count: frames * channels * bps)
        var signal = false
        _ = runMono(buf, frames: frames, channels: channels, ch: 1,
                    bytesPerSample: bps, isFloat: false, hasSignal: &signal)
        XCTAssertFalse(signal)
    }

    /// One non-zero byte in an otherwise silent block is signal, and only for its own
    /// channel. Pins the per-sample OR semantics the int24 branch relies on.
    func testInt24SingleNonZeroByteIsSignalOnItsChannelOnly() {
        let frames = Self.testFrames, channels = Self.testChannels, bps = 3
        var buf = [UInt8](repeating: 0, count: frames * channels * bps)
        let markedFrame = 5, markedChannel = 3, markedByte = 1
        buf[(markedFrame * channels + markedChannel) * bps + markedByte] = 0x01

        for ch in 0 ..< channels {
            var signal = false
            _ = runMono(buf, frames: frames, channels: channels, ch: ch,
                        bytesPerSample: bps, isFloat: false, hasSignal: &signal)
            XCTAssertEqual(signal, ch == markedChannel, "channel \(ch)")
        }
    }

    // MARK: - Stereo pairs
    //
    // demuxStereo had no coverage at all: neither extraction nor signal detection.

    func testStereoExtractionInterleavesBothChannels() {
        let frames = Self.testFrames, channels = Self.testChannels
        let left = 1, right = 3
        for bps in [2, 3, 4, 8] {
            let buf = interleaved(frames: frames, channels: channels, bytesPerSample: bps)
            var signal = false
            let got = runStereo(buf, frames: frames, channels: channels, left: left, right: right,
                                bytesPerSample: bps, isFloat: false, hasSignal: &signal)

            let wantL = expectedMono(from: buf, frames: frames, channels: channels, ch: left, bytesPerSample: bps)
            let wantR = expectedMono(from: buf, frames: frames, channels: channels, ch: right, bytesPerSample: bps)
            var want: [UInt8] = []
            for f in 0 ..< frames {
                want.append(contentsOf: wantL[f * bps ..< (f + 1) * bps])
                want.append(contentsOf: wantR[f * bps ..< (f + 1) * bps])
            }

            XCTAssertEqual(got, want, "bytesPerSample=\(bps)")
            XCTAssertTrue(signal, "bytesPerSample=\(bps)")
        }
    }

    /// A silent left channel must not mask signal present on the right one.
    func testStereoSignalFromRightChannelAlone() {
        let frames = Self.testFrames, channels = Self.testChannels, bps = 3
        var buf = [UInt8](repeating: 0, count: frames * channels * bps)
        let right = 2
        buf[(4 * channels + right) * bps] = 0x7F

        var signal = false
        _ = runStereo(buf, frames: frames, channels: channels, left: 0, right: right,
                      bytesPerSample: bps, isFloat: false, hasSignal: &signal)
        XCTAssertTrue(signal)
    }

    func testStereoAllZeroIsSilence() {
        let frames = Self.testFrames, channels = Self.testChannels, bps = 4
        let buf = [UInt8](repeating: 0, count: frames * channels * bps)
        var signal = false
        _ = runStereo(buf, frames: frames, channels: channels, left: 0, right: 1,
                      bytesPerSample: bps, isFloat: false, hasSignal: &signal)
        XCTAssertFalse(signal)
    }

    // MARK: - hasSignal accumulation
    //
    // The splitter passes the same flag across every block and every take. It must
    // latch on the first non-silent block and never be cleared by a later silent one.

    func testHasSignalLatchesAcrossBlocks() {
        let frames = Self.testFrames, channels = Self.testChannels
        for bps in [2, 3, 4, 8] {
            let loud = interleaved(frames: frames, channels: channels, bytesPerSample: bps)
            let silent = [UInt8](repeating: 0, count: frames * channels * bps)

            // Silent first: the flag must stay false.
            var signal = false
            _ = runMono(silent, frames: frames, channels: channels, ch: 0,
                        bytesPerSample: bps, isFloat: false, hasSignal: &signal)
            XCTAssertFalse(signal, "silent block must not set the flag (bps=\(bps))")

            // Then a loud block sets it, and a following silent block must not clear it.
            _ = runMono(loud, frames: frames, channels: channels, ch: 0,
                        bytesPerSample: bps, isFloat: false, hasSignal: &signal)
            XCTAssertTrue(signal, "loud block must set the flag (bps=\(bps))")

            _ = runMono(silent, frames: frames, channels: channels, ch: 0,
                        bytesPerSample: bps, isFloat: false, hasSignal: &signal)
            XCTAssertTrue(signal, "silent block must not clear the flag (bps=\(bps))")
        }
    }

    /// float32 -0.0 across a full interleaved block stays silence, and int32 does not.
    func testNegativeZeroIsSilenceOnlyForFloat() {
        let frames = Self.testFrames, channels = Self.testChannels, bps = 4
        var buf = [UInt8](repeating: 0, count: frames * channels * bps)
        for f in 0 ..< frames {
            buf[(f * channels + 1) * bps + 3] = 0x80      // -0.0f / INT32_MIN, little-endian
        }

        var floatSignal = false
        _ = runMono(buf, frames: frames, channels: channels, ch: 1,
                    bytesPerSample: bps, isFloat: true, hasSignal: &floatSignal)
        XCTAssertFalse(floatSignal)

        var intSignal = false
        _ = runMono(buf, frames: frames, channels: channels, ch: 1,
                    bytesPerSample: bps, isFloat: false, hasSignal: &intSignal)
        XCTAssertTrue(intSignal)
    }
}
