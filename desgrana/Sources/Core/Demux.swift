// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// swiftlint:disable cyclomatic_complexity

// MARK: - Raw-byte demultiplexing helpers
//
// These functions copy one channel (or a stereo pair) out of an interleaved
// raw byte buffer into a packed output buffer, while detecting whether any
// non-zero sample is present (used to cull silent tracks).
//
// The 2- and 4-byte paths use typed pointer loads/stores to avoid the per-frame
// overhead of calling memcpy for tiny transfers. The generic path falls back to
// byte-by-byte copy and handles 3-byte (int24) and any other size.

/// Demultiplexes one mono channel from `rawIn` into `monoOut` and updates `hasSignal`.
/// - Parameters:
///   - rawIn:        interleaved source buffer (frames × numChannels × bytesPerSample)
///   - monoOut:      destination buffer (frames × bytesPerSample)
///   - frames:       number of frames to process
///   - numChannels:  total channel count in the source
///   - ch:           0-indexed channel to extract
///   - bytesPerSample: bytes per sample (e.g. 4 for float32 / int32, 3 for int24)
///   - isFloat:      true for IEEE float samples; masks the sign bit so ±0.0 both count as silence
///   - hasSignal:    set to true if any non-zero sample is found (never reset to false)
public func demuxMono(
    from rawIn: UnsafePointer<UInt8>,
    to monoOut: UnsafeMutablePointer<UInt8>,
    frames: Int,
    numChannels: Int,
    ch: Int,
    bytesPerSample: Int,
    isFloat: Bool,
    hasSignal: inout Bool
) {
    switch bytesPerSample {
    case 4:
        // float32: mask the sign bit so +0.0 and -0.0 are both silence.
        // int32: compare raw, so full-scale negative (0x80000000) counts as signal.
        let mask: UInt32 = isFloat ? 0x7FFF_FFFF : 0xFFFF_FFFF
        rawIn.withMemoryRebound(to: UInt32.self, capacity: frames * numChannels) { src in
            monoOut.withMemoryRebound(to: UInt32.self, capacity: frames) { dst in
                for f in 0..<frames {
                    let v = src[f * numChannels + ch]
                    dst[f] = v
                    if !hasSignal && (v & mask) != 0 { hasSignal = true }
                }
            }
        }

    case 2:
        rawIn.withMemoryRebound(to: UInt16.self, capacity: frames * numChannels) { src in
            monoOut.withMemoryRebound(to: UInt16.self, capacity: frames) { dst in
                for f in 0..<frames {
                    let v = src[f * numChannels + ch]
                    dst[f] = v
                    if !hasSignal && v != 0 { hasSignal = true }
                }
            }
        }

    default: // int24 or other — byte-by-byte
        let frameStride = numChannels * bytesPerSample
        for f in 0..<frames {
            let srcOff = f * frameStride + ch * bytesPerSample
            let dstOff = f * bytesPerSample
            var sig = false
            for b in 0..<bytesPerSample {
                let byte = rawIn[srcOff + b]
                monoOut[dstOff + b] = byte
                if byte != 0 { sig = true }
            }
            if sig { hasSignal = true }
        }
    }
}

/// Demultiplexes a stereo pair from `rawIn` into `stereoOut` (interleaved L/R)
/// and updates `hasSignal`.
public func demuxStereo(
    from rawIn: UnsafePointer<UInt8>,
    to stereoOut: UnsafeMutablePointer<UInt8>,
    frames: Int,
    numChannels: Int,
    left: Int,
    right: Int,
    bytesPerSample: Int,
    isFloat: Bool,
    hasSignal: inout Bool
) {
    switch bytesPerSample {
    case 4:
        // float32: mask the sign bit (±0.0 = silence). int32: compare raw.
        let mask: UInt32 = isFloat ? 0x7FFF_FFFF : 0xFFFF_FFFF
        rawIn.withMemoryRebound(to: UInt32.self, capacity: frames * numChannels) { src in
            stereoOut.withMemoryRebound(to: UInt32.self, capacity: frames * 2) { dst in
                for f in 0..<frames {
                    let l = src[f * numChannels + left]
                    let r = src[f * numChannels + right]
                    dst[f * 2]     = l
                    dst[f * 2 + 1] = r
                    if !hasSignal && ((l & mask) != 0 || (r & mask) != 0) { hasSignal = true }
                }
            }
        }
    case 2:
        rawIn.withMemoryRebound(to: UInt16.self, capacity: frames * numChannels) { src in
            stereoOut.withMemoryRebound(to: UInt16.self, capacity: frames * 2) { dst in
                for f in 0..<frames {
                    let l = src[f * numChannels + left]
                    let r = src[f * numChannels + right]
                    dst[f * 2]     = l
                    dst[f * 2 + 1] = r
                    if !hasSignal && (l != 0 || r != 0) { hasSignal = true }
                }
            }
        }
    default: // int24 or other
        let frameStride = numChannels * bytesPerSample
        for f in 0..<frames {
            let dstOff = f * 2 * bytesPerSample
            var sig = false
            for b in 0..<bytesPerSample {
                let lb = rawIn[f * frameStride + left  * bytesPerSample + b]
                let rb = rawIn[f * frameStride + right * bytesPerSample + b]
                stereoOut[dstOff + b]                  = lb
                stereoOut[dstOff + bytesPerSample + b] = rb
                if lb != 0 || rb != 0 { sig = true }
            }
            if sig { hasSignal = true }
        }
    }
}

// swiftlint:enable cyclomatic_complexity
