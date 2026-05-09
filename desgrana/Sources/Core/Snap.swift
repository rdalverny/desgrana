// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Wing snapshot (.snap) parser
//
// A Wing snapshot is a JSON file produced by the Behringer Wing console.
// The format is documented in "WING Remote Protocols" by Patrick-Gilles Maillot.
//
// Stereo linking: ae_data.ch.<N>.clink == true means "N is the left of a stereo pair".
// The Wing sets clink=true on BOTH channels of a linked pair (left AND right), so we
// must skip channel N if it was already claimed as the right side of a previous pair.
//
// Channel names: ae_data.ch.<N>.name holds the strip label (often empty by default).
// Fallback: follow the input routing ae_data.ch.<N>.in.conn → ae_data.io.in.[grp][in].name.

public struct SnapInfo {
    /// Stereo pairs derived from clink=true channels (1-indexed, always odd+even adjacent).
    public let stereoPairs: [StereoPair]
    /// Channel names keyed by 1-based channel number. Empty-string names are omitted.
    public let channelNames: [Int: String]
    /// Scene name extracted from active_scene path (e.g. "LIVE TRIPLE B").
    public let sceneName: String?
    /// Show (folder) name extracted from active_scene path (e.g. "ROCK THE END").
    public let showName: String?
}

public enum SnapError: Error, CustomStringConvertible {
    case cannotRead(String)
    case invalidJSON(String)
    case missingChannelData

    public var description: String {
        switch self {
        case .cannotRead(let p):    return "Cannot read snap file: \(p)"
        case .invalidJSON(let m):  return "Invalid JSON in snap file: \(m)"
        case .missingChannelData:  return "Snap file has no ae_data.ch section"
        }
    }
}

// swiftlint:disable:next cyclomatic_complexity
public func parseSnap(at url: URL) throws -> SnapInfo {
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
        throw SnapError.cannotRead(url.path)
    }

    let root: Any
    do { root = try JSONSerialization.jsonObject(with: data) } catch {
        throw SnapError.invalidJSON(error.localizedDescription)
    }

    guard let dict = root as? [String: Any],
          let ae   = dict["ae_data"] as? [String: Any],
          let ch   = ae["ch"] as? [String: Any]
    else { throw SnapError.missingChannelData }

    var pairs: [StereoPair] = []
    var names: [Int: String] = [:]

    // Channel keys are "1"…"40" (string-keyed)
    let sorted = ch.keys.compactMap(Int.init).sorted()
    var claimedRight = Set<Int>()

    for n in sorted {
        guard let info = ch["\(n)"] as? [String: Any] else { continue }

        // Strip name — sanitize for use in filenames
        if let raw = info["name"] as? String {
            let sanitized = sanitizeChannelName(raw)
            if !sanitized.isEmpty { names[n] = sanitized }
        }

        // Stereo link — Wing sets clink=true on BOTH sides of a linked pair, so skip
        // channels that were already claimed as the right side of a previous pair.
        if let linked = info["clink"] as? Bool, linked, !claimedRight.contains(n) {
            pairs.append(StereoPair(left: n, right: n + 1))  // Wing always pairs adjacent channels
            claimedRight.insert(n + 1)
        }
    }

    // Fill missing names from physical input routing: ch.N.in.conn.{grp,in} → io.in.[grp][in].name
    if let io   = ae["io"] as? [String: Any],
       let ioIn = io["in"] as? [String: Any] {
        for n in sorted where names[n] == nil {
            guard let info   = ch["\(n)"] as? [String: Any],
                  let inBlk  = info["in"] as? [String: Any],
                  let conn   = inBlk["conn"] as? [String: Any],
                  let grp    = conn["grp"] as? String,
                  let inNum  = conn["in"] as? Int,
                  let grpMap = ioIn[grp] as? [String: Any],
                  let inInfo = grpMap["\(inNum)"] as? [String: Any],
                  let raw    = inInfo["name"] as? String
            else { continue }
            let sanitized = sanitizeChannelName(raw)
            if !sanitized.isEmpty { names[n] = sanitized }
        }
    }

    // Extract scene/show names from active_scene (e.g. "I:/ROCK THE END/LIVE TRIPLE B.snap")
    var sceneName: String?
    var showName: String?
    if let activeScene = dict["active_scene"] as? String, !activeScene.isEmpty {
        // Normalise Windows-style backslashes then split on both separators
        let parts = activeScene
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
        if let last = parts.last {
            let base = (last as NSString).deletingPathExtension
            if !base.isEmpty { sceneName = base }
        }
        if parts.count >= 2 {
            let parent = parts[parts.count - 2]
            // Skip drive letters (e.g. "I:")
            if parent.count > 2 { showName = parent }
        }
    }

    return SnapInfo(stereoPairs: pairs, channelNames: names, sceneName: sceneName, showName: showName)
}

/// Returns the first .snap file found in `dir`, or nil.
public func findSnap(in dir: URL) -> URL? {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { return nil }
    return contents
        .filter { $0.pathExtension.lowercased() == "snap" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .first
}

// MARK: - Auto-detect helpers

/// Returns the first console snapshot in `dir`: .snap first, then .scn.
public func findConsoleSnapshot(in dir: URL) -> URL? {
    findSnap(in: dir) ?? findX32Scene(in: dir)
}

/// Parses a Wing .snap or X32 .scn file, dispatching on the file extension.
public func parseSnapOrScene(at url: URL) throws -> SnapInfo {
    switch url.pathExtension.lowercased() {
    case "scn": return try parseX32Scene(at: url)
    default:    return try parseSnap(at: url)
    }
}
