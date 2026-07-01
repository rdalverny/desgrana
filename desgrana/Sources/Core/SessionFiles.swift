// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

/// Case variants to try when locating the Behringer SE_LOG binary on case-sensitive filesystems.
public let seLogCandidates = ["SE_LOG.BIN", "se_log.bin", "SE_LOG.bin"]

/// All `.wav` files directly in `dir`, sorted by name.
func wavFilesInDir(_ dir: URL) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return [] }
    return contents
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// The first file in `dir` with the given (case-insensitive) extension, by sorted name, or nil.
public func firstFile(in dir: URL, withExtension ext: String) -> URL? {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return nil }
    return contents
        .filter { $0.pathExtension.lowercased() == ext.lowercased() }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .first
}

/// Find WAV takes in session directory (hex-named: 00000001.wav …), sorted by name.
/// This is the Behringer Wing/X-Live convention: ordered parts of one continuous
/// recording, split at the 4 GB FAT32 limit.
public func findWavTakes(in dir: URL) -> [URL] {
    wavFilesInDir(dir)
        .filter { UInt64($0.deletingPathExtension().lastPathComponent, radix: 16) != nil }
}

/// Outcome of resolving whatever the user dropped / passed into a list of takes to split.
public enum SessionTakes: Equatable {
    case ok([URL])          // ready to split (hex takes, a single file, or a single WAV in a dir)
    case empty              // no WAV at all
    case ambiguous([URL])   // 2+ non-hex WAVs in a directory — refuse, can't guess intent
}

/// Resolve a dropped/passed input (a folder or a WAV file) into the takes to split.
///
/// Resolution order:
///  - a `.wav` file            → just that file
///  - a directory:
///     1. hex-named takes present → them (Behringer session, unchanged behaviour)
///     2. else exactly one WAV    → that file (other recorders, single multichannel WAV)
///     3. else several WAVs       → `.ambiguous` (we don't silently concatenate unrelated files)
public func resolveSessionTakes(at input: URL) -> SessionTakes {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir) else {
        return .empty
    }
    if !isDir.boolValue {
        return input.pathExtension.lowercased() == "wav" ? .ok([input]) : .empty
    }
    let hex = findWavTakes(in: input)
    if !hex.isEmpty { return .ok(hex) }
    let all = wavFilesInDir(input)
    switch all.count {
    case 0:  return .empty
    case 1:  return .ok(all)
    default: return .ambiguous(all)
    }
}

/// Minimal info read straight from a WAV file's header (no SE_LOG needed).
public struct WavHeaderInfo {
    public let channels: Int
    public let sampleRate: Double
    public let duration: Double   // seconds; 0 if the data size is unknown (e.g. 0xFFFFFFFF)
    public init(channels: Int, sampleRate: Double, duration: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

/// Recovers channel count, sample rate and duration from a WAV header (RF64-aware,
/// resolves WAVE_FORMAT_EXTENSIBLE). Used to populate the UI track list when there is
/// no SE_LOG.bin (other recorders). Returns nil if the file is not a readable WAV.
public func probeWavHeader(at url: URL) -> WavHeaderInfo? {
    guard let reader = try? WAVReader(url: url) else { return nil }
    defer { reader.close() }
    let sampleRate = Double(reader.format.sampleRate)
    guard reader.format.channels > 0, sampleRate > 0 else { return nil }
    let duration = reader.frameCount > 0 ? Double(reader.frameCount) / sampleRate : 0
    return WavHeaderInfo(channels: reader.format.channels, sampleRate: sampleRate, duration: duration)
}

/// Reads the full source format (channels, sample rate, bit depth, float flag) from a
/// WAV header. Used by the extraction report in dry-run, before any split runs.
public func probeSourceFormat(at url: URL) -> SourceFormat? {
    guard let reader = try? WAVReader(url: url) else { return nil }
    defer { reader.close() }
    let fmt = reader.format
    guard fmt.channels > 0, fmt.sampleRate > 0 else { return nil }
    return SourceFormat(channels: fmt.channels, sampleRate: fmt.sampleRate,
                        bitsPerSample: fmt.bitsPerSample, isFloat: fmt.isFloat)
}

/// Returns the raw payload of a pre-`data` metadata chunk (e.g. "bext", "iXML"), or nil.
/// Backed by WAVReader's single header walk (see `WAVReader.metadata`).
func riffChunk(at url: URL, id: String) -> Data? {
    (try? WAVReader(url: url))?.metadataChunk(id)
}

/// Derives a filename suffix from channel name(s).
/// Stereo: detects _L/_R (or -L/-R / " L"/" R") pairs and strips the suffix → "OH".
/// Otherwise concatenates non-empty names: "VoxL-VoxR". Returns "" if no name.
public func channelNameSuffix(for channels: [Int], names: [Int: String]) -> String {
    let parts = channels.map { names[$0] ?? "" }
    guard !parts.isEmpty else { return "" }
    if parts.count == 2 {
        if let base = sharedStereoBase(left: parts[0], right: parts[1]) { return "_\(base)" }
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
