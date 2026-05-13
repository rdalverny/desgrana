// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Shared public types

public struct StereoPair: Equatable {
    public let left: Int   // 1-indexed
    public let right: Int  // 1-indexed
    public init(left: Int, right: Int) {
        self.left = left
        self.right = right
    }
}

public struct SplitResult {
    public let urls: [URL]
    public let keptMono: Int
    public let keptStereo: Int
    public let silentSkipped: Int
    public let totalFrames: UInt64
    public let sampleRate: Double
    public init(urls: [URL], keptMono: Int, keptStereo: Int, silentSkipped: Int, totalFrames: UInt64, sampleRate: Double) {
        self.urls = urls
        self.keptMono = keptMono
        self.keptStereo = keptStereo
        self.silentSkipped = silentSkipped
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
    }
}

public enum SplitError: Error, CustomStringConvertible {
    case noWavFiles
    case cannotOpenInput(String)           // file path (embed status in string if relevant)
    case cannotCreateOutput(String)        // file path
    case cannotGetFormat(Int32)            // AudioToolbox OSStatus (macOS only)
    case cannotSetClientFormat(Int32)      // AudioToolbox OSStatus (macOS only)
    case readError(Int32)                  // AudioToolbox OSStatus (macOS only)
    case writeError(Int32)                 // AudioToolbox OSStatus (macOS only)
    case channelMismatch(expected: Int, got: Int, file: String)
    public var description: String {
        switch self {
        case .noWavFiles:
            return "No WAV take files found in session directory"
        case .cannotOpenInput(let f):
            return "Cannot open input '\(f)'"
        case .cannotCreateOutput(let f):
            return "Cannot create output '\(f)'"
        case .cannotGetFormat(let s):
            return "Cannot read input format (OSStatus \(s))"
        case .cannotSetClientFormat(let s):
            return "Cannot set client format (OSStatus \(s))"
        case .readError(let s):
            return "Read error (OSStatus \(s))"
        case .writeError(let s):
            return "Write error (OSStatus \(s))"
        case .channelMismatch(let exp, let got, let f):
            return "\(f): expected \(exp) channels, got \(got)"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .noWavFiles, .cannotOpenInput, .cannotCreateOutput,
             .readError, .writeError:                               return 2
        case .cannotGetFormat, .cannotSetClientFormat,
             .channelMismatch:                                      return 3
        }
    }
}

/// Progress callback: (currentTake, totalTakes, framesProcessedInTake)
public typealias ProgressCallback = (_ take: Int, _ totalTakes: Int, _ framesInTake: UInt64) -> Void

/// Logical kind of an output track.
public enum TrackKind {
    case mono(ch: Int)                  // 0-indexed
    case stereo(left: Int, right: Int)  // 0-indexed
}

/// Platform-independent description of one output track (URL + kind).
public struct OutputSpec {
    public let kind: TrackKind
    public let url: URL
}
