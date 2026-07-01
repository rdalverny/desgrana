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

/// One written output file: its URL, per-channel track names (1 entry for a mono
/// file, 2 for a stereo L/R file; empty when the source channel had no name), its
/// kind, and the 1-indexed source channels it draws from.
public struct OutputFile {
    public let url: URL
    public let trackNames: [String]
    public let kind: TrackKind
    /// 1-indexed source channel(s): [ch] for mono, [left, right] for stereo.
    public let channels: [Int]
    public init(url: URL, trackNames: [String], kind: TrackKind, channels: [Int]) {
        self.url = url
        self.trackNames = trackNames
        self.kind = kind
        self.channels = channels
    }
}

/// Format of the source takes, read once from the first WAV header.
public struct SourceFormat {
    public let channels: Int
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let isFloat: Bool
    public init(channels: Int, sampleRate: Int, bitsPerSample: Int, isFloat: Bool) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
    }
}

public struct SplitResult {
    /// Kept (non-silent) output files.
    public let outputs: [OutputFile]
    /// Files that were written then removed because the channel(s) carried no signal.
    public let dropped: [OutputFile]
    public let keptMono: Int
    public let keptStereo: Int
    public let silentSkipped: Int
    public let totalFrames: UInt64
    public let sampleRate: Double
    /// Source format read from the first take (nil only if never populated).
    public let sourceFormat: SourceFormat?
    public init(
        outputs: [OutputFile], dropped: [OutputFile] = [],
        keptMono: Int, keptStereo: Int, silentSkipped: Int,
        totalFrames: UInt64, sampleRate: Double, sourceFormat: SourceFormat? = nil
    ) {
        self.outputs = outputs
        self.dropped = dropped
        self.keptMono = keptMono
        self.keptStereo = keptStereo
        self.silentSkipped = silentSkipped
        self.totalFrames = totalFrames
        self.sampleRate = sampleRate
        self.sourceFormat = sourceFormat
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

    public var isStereo: Bool { if case .stereo = self { return true }; return false }
    public var channelCount: Int { isStereo ? 2 : 1 }

    /// 1-indexed source channel(s): [ch] for mono, [left, right] for stereo.
    public var sourceChannels: [Int] {
        switch self {
        case .mono(let ch):           return [ch + 1]
        case .stereo(let l, let r):   return [l + 1, r + 1]
        }
    }
}

/// Platform-independent description of one output track (URL + kind).
public struct OutputSpec {
    public let kind: TrackKind
    public let url: URL
    /// Per-channel source names for this file (1 for mono, 2 for stereo L/R).
    /// Empty strings for unnamed channels. Used to embed iXML track names.
    public let trackNames: [String]
    public init(kind: TrackKind, url: URL, trackNames: [String] = []) {
        self.kind = kind
        self.url = url
        self.trackNames = trackNames
    }
}
