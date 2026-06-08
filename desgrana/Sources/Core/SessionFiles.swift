// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

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
    func tag(_ b: [UInt8], _ o: Int) -> String { String(bytes: b[o ..< o + 4], encoding: .ascii) ?? "" }

    guard let riff = read(12), tag(riff, 0) == "RIFF" || tag(riff, 0) == "RF64", tag(riff, 8) == "WAVE" else {
        return nil
    }

    var channels = 0
    var sampleRate = 0.0
    var bits = 0
    var dataSize: UInt64 = 0

    // Walk chunks until we hit `data` (whose payload we never read) or EOF.
    while let hdr = read(8) {
        let id = tag(hdr, 0)
        let size = u32(hdr, 4)
        if id == "fmt " {
            guard let body = read(Int(size) + Int(size & 1)) else { break }
            channels   = u16(body, 2)
            sampleRate = Double(u32(body, 4))
            bits       = u16(body, 14)
        } else if id == "data" {
            dataSize = UInt64(size)
            break
        } else {
            // Skip this chunk's payload (small: fact/bext/iXML come before `data`).
            guard read(Int(size) + Int(size & 1)) != nil else { break }
        }
    }

    guard channels > 0, sampleRate > 0 else { return nil }
    let frameBytes = channels * max(bits / 8, 1)
    let duration = (dataSize > 0 && dataSize != 0xFFFF_FFFF && frameBytes > 0)
        ? Double(dataSize) / Double(frameBytes) / sampleRate
        : 0
    return WavHeaderInfo(channels: channels, sampleRate: sampleRate, duration: duration)
}

/// Reads per-channel track names embedded in the WAV's `iXML` chunk, when present.
///
/// Field recorders (Sound Devices, Zoom F-series, Tascam) embed an `iXML` chunk with a
/// `<TRACK_LIST>` carrying a `<NAME>` per channel — the in-file analogue of the Wing
/// `.snap`. Parsing it would let the "other recorder" fallback name tracks instead of
/// numbering them, then existing L/R-suffix pairing applies on top.
///
/// Placeholder (iXML): not implemented. Returns an empty map, so callers fall back to
/// numbered channels (current behaviour). To implement: locate the `iXML` RIFF chunk,
/// parse its XML `<TRACK_LIST>/<TRACK>` entries and map `<INTERLEAVE_INDEX>` (1-indexed)
/// → `<NAME>`. Verify the exact schema against the iXML spec and a real recorder sample
/// first. Tracked separately as "read track names from field recorders (iXML)".
public func parseIXMLTrackNames(at url: URL) -> [Int: String] {
    // iXML placeholder: parse the iXML chunk's <TRACK_LIST> here and return [channel: name].
    return [:]
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
