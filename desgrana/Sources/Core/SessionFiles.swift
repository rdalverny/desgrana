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

// swiftlint:disable cyclomatic_complexity
/// Parse just the `fmt `/`data` chunks of a WAV to recover channel count, sample rate and
/// duration — used to populate the UI track list when there is no SE_LOG.bin (other
/// recorders). Cross-platform (pure RIFF parsing), mirrors `read_wav_fmt` in the tests.
public func probeWavHeader(at url: URL) -> WavHeaderInfo? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }

    func read(_ n: Int) -> [UInt8]? {
        guard let d = try? fh.read(upToCount: n), d.count == n else { return nil }
        return [UInt8](d)
    }
    func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
    func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
    func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | (UInt64(b[o + $1]) << (8 * $1)) }
    }
    func tag(_ b: [UInt8], _ o: Int) -> String { String(bytes: b[o ..< o + 4], encoding: .ascii) ?? "" }

    guard let riff = read(12), tag(riff, 0) == "RIFF" || tag(riff, 0) == "RF64", tag(riff, 8) == "WAVE" else {
        return nil
    }

    var channels = 0
    var sampleRate = 0.0
    var bits = 0
    var dataSize: UInt64 = 0
    var ds64DataSize: UInt64?    // real `data` size for RF64 (>4 GB) files

    // Walk chunks until we hit `data` (whose payload we never read) or EOF.
    while let hdr = read(8) {
        let id = tag(hdr, 0)
        let size = u32(hdr, 4)
        if id == "ds64" {
            // RF64 64-bit sizes: riffSize(8), dataSize(8), sampleCount(8), table...
            guard let body = read(Int(size) + Int(size & 1)) else { break }
            if body.count >= 16 { ds64DataSize = u64(body, 8) }
        } else if id == "fmt " {
            guard let body = read(Int(size) + Int(size & 1)) else { break }
            channels   = u16(body, 2)
            sampleRate = Double(u32(body, 4))
            bits       = u16(body, 14)
        } else if id == "data" {
            // RF64 stores 0xFFFF_FFFF here and the real size in ds64.
            dataSize = (size == 0xFFFF_FFFF) ? (ds64DataSize ?? 0) : UInt64(size)
            break
        } else {
            // Skip this chunk's payload (small: fact/bext/iXML come before `data`).
            guard read(Int(size) + Int(size & 1)) != nil else { break }
        }
    }

    guard channels > 0, sampleRate > 0 else { return nil }
    let frameBytes = channels * max(bits / 8, 1)
    let duration = (dataSize > 0 && frameBytes > 0)
        ? Double(dataSize) / Double(frameBytes) / sampleRate
        : 0
    return WavHeaderInfo(channels: channels, sampleRate: sampleRate, duration: duration)
}
// swiftlint:enable cyclomatic_complexity

/// Returns the raw payload of the first RIFF chunk with `id` (4 chars, e.g. "iXML"), or nil.
/// Walks the chunk list, seeking past payloads (so it tolerates a large `data` chunk before
/// the target — though metadata chunks normally precede `data`).
func riffChunk(at url: URL, id: String) -> Data? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    func read(_ n: Int) -> [UInt8]? {
        guard let d = try? fh.read(upToCount: n), d.count == n else { return nil }
        return [UInt8](d)
    }
    func tag(_ b: [UInt8], _ o: Int) -> String { String(bytes: b[o ..< o + 4], encoding: .ascii) ?? "" }
    func u32(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(b[o]) | (UInt64(b[o + 1]) << 8) | (UInt64(b[o + 2]) << 16) | (UInt64(b[o + 3]) << 24)
    }
    func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | (UInt64(b[o + $1]) << (8 * $1)) }
    }
    guard let riff = read(12), tag(riff, 0) == "RIFF" || tag(riff, 0) == "RF64", tag(riff, 8) == "WAVE" else {
        return nil
    }
    var offset: UInt64 = 12
    var ds64DataSize: UInt64?
    while let hdr = read(8) {
        let cid = tag(hdr, 0)
        var size = u32(hdr, 4)
        offset += 8                                   // now at payload start
        if cid == id {
            guard let d = try? fh.read(upToCount: Int(size)), d.count == Int(size) else { return nil }
            return d
        }
        if cid == "ds64", let body = read(Int(size)), body.count >= 16 {
            ds64DataSize = u64(body, 8)
        } else if cid == "data", size == 0xFFFF_FFFF, let real = ds64DataSize {
            size = real                               // RF64: real `data` size lives in ds64
        }
        offset += size + (size & 1)                   // skip payload + RIFF pad byte
        guard (try? fh.seek(toOffset: offset)) != nil else { return nil }
    }
    return nil
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
