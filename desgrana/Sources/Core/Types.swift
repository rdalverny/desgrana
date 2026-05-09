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

// MARK: - Shared utilities

/// Returns only the pairs that are valid for `channelCount`, skipping out-of-range or
/// overlapping entries. Used by the App to filter snap pairs against session channel count.
public func filterStereoPairs(_ pairs: [StereoPair], channelCount: Int) -> [StereoPair] {
    var seen = Set<Int>()
    var result: [StereoPair] = []
    for pair in pairs {
        guard pair.left  >= 1 && pair.left  <= channelCount,
              pair.right >= 1 && pair.right <= channelCount else { continue }
        var ok = true
        for ch in [pair.left, pair.right] {
            if !seen.insert(ch).inserted {
                ok = false
                break
            }
        }
        if ok { result.append(pair) }
    }
    return result
}

/// Detects stereo pairs from channel names by looking for adjacent channels sharing
/// a common base name with L/R suffixes (_L/_R, -L/-R, " L"/" R").
/// Channels without names or without a matching suffix are left as mono.
public func detectStereoPairsFromNames(_ names: [Int: String], channelCount: Int) -> [StereoPair] {
    var pairs: [StereoPair] = []
    var claimed = Set<Int>()
    for ch in 1 ..< channelCount {
        guard !claimed.contains(ch) else { continue }
        let next = ch + 1
        guard !claimed.contains(next) else { continue }
        let l = names[ch] ?? ""
        let r = names[next] ?? ""
        guard !l.isEmpty, !r.isEmpty else { continue }
        for sep in ["_", "-", " "] {
            if l.hasSuffix("\(sep)L") && r.hasSuffix("\(sep)R") {
                let base = String(l.dropLast(sep.count + 1))
                if base == String(r.dropLast(sep.count + 1)), !base.isEmpty {
                    pairs.append(StereoPair(left: ch, right: next))
                    claimed.insert(ch); claimed.insert(next)
                    break
                }
            }
        }
    }
    return pairs
}

/// Validates stereo pairs against `channelCount` for use inside `splitSession`.
/// Prints warnings for rejected pairs and returns the accepted pairs + claimed channel set.
public func validateStereoPairs(
    _ pairs: [StereoPair],
    channelCount: Int
) -> (active: [StereoPair], paired: Set<Int>) {
    var seen = Set<Int>()
    var active: [StereoPair] = []
    for pair in pairs {
        guard pair.left >= 1 && pair.left <= channelCount &&
              pair.right >= 1 && pair.right <= channelCount else {
            fputs("Warning: stereo pair \(pair.left):\(pair.right) skipped — channel numbers must be in 1...\(channelCount)\n", stderr)
            continue
        }
        var overlap = false
        for ch in [pair.left, pair.right] {
            if !seen.insert(ch).inserted {
                fputs("Warning: stereo pair \(pair.left):\(pair.right) skipped -- channel \(ch) appears in multiple pairs\n", stderr)
                overlap = true
                break
            }
        }
        if !overlap { active.append(pair) }
    }
    return (active, seen)
}

/// Find WAV takes in session directory (hex-named: 00000001.wav …), sorted by name.
public func findWavTakes(in dir: URL) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return [] }
    return contents
        .filter { $0.pathExtension.lowercased() == "wav" }
        .filter { UInt64($0.deletingPathExtension().lastPathComponent, radix: 16) != nil }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Derives a filename suffix from channel name(s).
/// Stereo: detects _L/_R (or -L/-R / " L"/" R") pairs and strips the suffix → "OH".
/// Otherwise concatenates non-empty names: "VoxL-VoxR". Returns "" if no name.
public func channelNameSuffix(for channels: [Int], names: [Int: String]) -> String {
    let parts = channels.map { names[$0] ?? "" }
    guard !parts.isEmpty else { return "" }
    if parts.count == 2 {
        let l = parts[0], r = parts[1]
        for sep in ["_", "-", " "] {
            if l.hasSuffix("\(sep)L") && r.hasSuffix("\(sep)R") {
                let base  = String(l.dropLast(sep.count + 1))
                let rBase = String(r.dropLast(sep.count + 1))
                if base == rBase && !base.isEmpty { return "_\(base)" }
            }
        }
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "-")
        return joined.isEmpty ? "" : "_\(joined)"
    }
    return parts[0].isEmpty ? "" : "_\(parts[0])"
}

// MARK: - Shared string helpers

/// Strips characters unsafe for filenames and collapses whitespace to underscores.
func sanitizeChannelName(_ raw: String) -> String {
    let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
    return raw
        .components(separatedBy: unsafe).joined()
        .trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
}

/// Prints the split result summary to stdout.
public func printSplitSummary(
    keptMono: Int, keptStereo: Int,
    silentCount: Int,
    totalFrames: UInt64, sampleRate: Double,
    outputDir: URL
) {
    print()
    if keptStereo > 0 {
        print("Done: \(keptMono) mono + \(keptStereo) stereo files", terminator: "")
    } else {
        print("Done: \(keptMono) mono files", terminator: "")
    }
    if silentCount > 0 { print(", \(silentCount) silent skipped", terminator: "") }
    print(", \(totalFrames) frames (\(formatTime(Double(totalFrames) / sampleRate)))")
    print("Output: \(outputDir.path)")
}
