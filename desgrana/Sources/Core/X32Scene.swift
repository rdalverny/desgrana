// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - X32 scene (.scn) parser
//
// An X32 scene file is plain-text OSC key/value, one parameter per line:
//   /path/to/param value
// String values are double-quoted; numbers and booleans are bare.
// Comments start with #. Paths are zero-padded (/ch/01/, not /ch/1/).
//
// Relevant fields extracted here:
//   /ch/XX/config/name "Name"    — strip label (XX = 01..32)
//   /config/chlink1-2 ON         — stereo link for odd+even pair (also chlink01-02)
//   /show/name "Scene Name"      — optional scene name

public enum X32SceneError: Error, CustomStringConvertible {
    case cannotRead(String)

    public var description: String {
        switch self {
        case .cannotRead(let p): return "Cannot read X32 scene file: \(p)"
        }
    }
}

public func parseX32Scene(at url: URL) throws -> SnapInfo {
    let text: String
    do {
        text = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw X32SceneError.cannotRead(url.path)
    }

    var names: [Int: String] = [:]
    var pairs: [StereoPair] = []
    var sceneName: String?

    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

        // Split on first whitespace: path + optional value
        guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
        let path = String(trimmed[trimmed.startIndex..<spaceIdx])
        let rawValue = trimmed[trimmed.index(after: spaceIdx)...]
            .trimmingCharacters(in: .whitespaces)

        // /ch/XX/config/name "Name"
        if let ch = channelNumber(from: path, suffix: "/config/name") {
            let name = sanitizeChannelName(unquote(String(rawValue)))
            if !name.isEmpty { names[ch] = name }
            continue
        }

        // /config/chlink<n1>-<n2> ON|1
        if path.hasPrefix("/config/chlink"), let (n1, n2) = parseLinkKey(path) {
            if rawValue == "ON" || rawValue == "1" {
                pairs.append(StereoPair(left: n1, right: n2))
            }
            continue
        }

        // /show/name "Scene"
        if path == "/show/name" {
            let name = unquote(String(rawValue))
            if !name.isEmpty { sceneName = name }
            continue
        }
    }

    let resolvedScene = sceneName ?? url.deletingPathExtension().lastPathComponent

    return SnapInfo(stereoPairs: pairs, channelNames: names, sceneName: resolvedScene, showName: nil)
}

/// Returns the first .scn file found in `dir`, or nil.
public func findX32Scene(in dir: URL) -> URL? {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return nil }
    return contents
        .filter { $0.pathExtension.lowercased() == "scn" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .first
}

// MARK: - Private helpers

/// Extracts the 1-based channel number from a path like `/ch/01/config/name`.
private func channelNumber(from path: String, suffix: String) -> Int? {
    guard path.hasPrefix("/ch/") else { return nil }
    let afterCh = path.dropFirst("/ch/".count)
    guard let slashIdx = afterCh.firstIndex(of: "/") else { return nil }
    let numStr = String(afterCh[afterCh.startIndex..<slashIdx])
    guard let n = Int(numStr), n >= 1 else { return nil }
    let rest = String(afterCh[slashIdx...])
    return rest == suffix ? n : nil
}

/// Parses `/config/chlink1-2` or `/config/chlink01-02` → (1, 2).
private func parseLinkKey(_ path: String) -> (Int, Int)? {
    let prefix = "/config/chlink"
    guard path.hasPrefix(prefix) else { return nil }
    let tail = path.dropFirst(prefix.count)  // "1-2" or "01-02"
    let parts = tail.split(separator: "-", maxSplits: 1)
    guard parts.count == 2,
          let n1 = Int(parts[0]),
          let n2 = Int(parts[1]),
          n1 >= 1, n2 >= 1, n1 < n2
    else { return nil }
    return (n1, n2)
}

/// Strips surrounding double-quotes from a string value if present.
private func unquote(_ s: String) -> String {
    guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
    return String(s.dropFirst().dropLast())
}
