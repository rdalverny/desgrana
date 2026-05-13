// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

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
