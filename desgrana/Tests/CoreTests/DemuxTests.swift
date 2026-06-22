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
}
