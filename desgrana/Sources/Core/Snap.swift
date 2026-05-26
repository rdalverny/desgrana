// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Wing snapshot (.snap) parser
//
// A Wing snapshot is a JSON file produced by the Behringer Wing console.
// Documented in "WING Remote Protocols" by Patrick-Gilles Maillot.
//
// Two stereo mechanisms:
//   LCL (channel-strip link): ae_data.ch.N.clink is true on both channels of a linked pair.
//   USB stereo: ae_data.io.in.USB.N.mode is "ST" or "M/S"; one Wing channel occupies two
//   consecutive USB inputs, so the WAV pair is (USB-in, USB-in+1).
//
// WAV track numbers follow USB input numbers for USB stereo, channel numbers for LCL.
// Channel names are keyed by WAV track number; right sides of USB pairs get no name.

public struct SnapInfo {
    /// Stereo pairs, 1-indexed. LCL pairs are always adjacent channels; USB pairs follow input numbers.
    public let stereoPairs: [StereoPair]
    /// Channel names keyed by 1-based WAV track number. Empty-string names are omitted.
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

    let sorted = ch.keys.compactMap(Int.init).sorted()
    let ioIn   = (ae["io"] as? [String: Any]).flatMap { $0["in"] as? [String: Any] }
    let usbIO  = ioIn?["USB"] as? [String: Any]

    let routes            = channelRoutes(channels: ch, sorted: sorted, usbIO: usbIO)
    let (pairs, usbPairs) = collectPairs(sorted: sorted, routes: routes)
    let names             = collectNames(sorted: sorted, routes: routes, usbPairs: usbPairs, ioIn: ioIn)
    let (sceneName, showName) = sceneAndShow(from: dict["active_scene"] as? String)

    return SnapInfo(stereoPairs: pairs, channelNames: names, sceneName: sceneName, showName: showName)
}

// MARK: - Helpers

/// Parsed data for one Wing channel, keyed by channel number.
private struct ChannelRoute {
    let trackKey: Int       // 1-based WAV track number (= USB input for USB stereo, channel number otherwise)
    let isUsbStereo: Bool
    let clink: Bool
    let name: String?
    let inputGroup: String? // ae_data.ch.N.in.conn.grp
    let inputNumber: Int?   // ae_data.ch.N.in.conn.in
}

/// Parses each Wing channel into a typed ChannelRoute. Single point of contact with the raw JSON.
private func channelRoutes(
    channels: [String: Any],
    sorted: [Int],
    usbIO: [String: Any]?
) -> [Int: ChannelRoute] {
    var result: [Int: ChannelRoute] = [:]
    for n in sorted {
        guard let info = channels["\(n)"] as? [String: Any] else { continue }
        let conn  = (info["in"] as? [String: Any]).flatMap { $0["conn"] as? [String: Any] }
        let clink = info["clink"] as? Bool ?? false
        let name  = info["name"] as? String
        let grp   = conn?["grp"] as? String
        let inNum = conn?["in"] as? Int
        if grp == "USB",
           let usbIn = inNum,
           let mode  = (usbIO?["\(usbIn)"] as? [String: Any])?["mode"] as? String,
           mode == "ST" || mode == "M/S" {
            result[n] = ChannelRoute(trackKey: usbIn, isUsbStereo: true,
                                     clink: clink, name: name,
                                     inputGroup: grp, inputNumber: inNum)
        } else {
            result[n] = ChannelRoute(trackKey: n, isUsbStereo: false,
                                     clink: clink, name: name,
                                     inputGroup: grp, inputNumber: inNum)
        }
    }
    return result
}

/// Collects stereo pairs from LCL (clink) and USB stereo sources.
/// Both sides of every pair are claimed to prevent duplicates when a USB input number
/// coincides with a Wing channel number that also has clink=true.
private func collectPairs(
    sorted: [Int],
    routes: [Int: ChannelRoute]
) -> (pairs: [StereoPair], usbPairs: [StereoPair]) {
    var pairs: [StereoPair] = []
    var usbPairs: [StereoPair] = []
    var claimed = Set<Int>()
    for n in sorted {
        guard let route = routes[n] else { continue }
        guard route.isUsbStereo || route.clink,
              !claimed.contains(route.trackKey) else { continue }
        let pair = StereoPair(left: route.trackKey, right: route.trackKey + 1)
        pairs.append(pair)
        claimed.insert(route.trackKey)
        claimed.insert(route.trackKey + 1)
        if route.isUsbStereo { usbPairs.append(pair) }
    }
    return (pairs, usbPairs)
}

/// Collects channel names keyed by WAV track number.
/// Primary source: ae_data.ch.N.name. Fallback: ae_data.io.in.[grp][in].name.
/// Right sides of USB stereo pairs are skipped — no Wing channel strip maps to them.
private func collectNames(
    sorted: [Int],
    routes: [Int: ChannelRoute],
    usbPairs: [StereoPair],
    ioIn: [String: Any]?
) -> [Int: String] {
    var names: [Int: String] = [:]
    let usbRightTracks = Set(usbPairs.map(\.right))

    for n in sorted {
        guard let route = routes[n],
              !usbRightTracks.contains(route.trackKey),
              names[route.trackKey] == nil,
              let raw = route.name
        else { continue }
        let s = sanitizeChannelName(raw)
        if !s.isEmpty { names[route.trackKey] = s }
    }

    guard let ioIn else { return names }
    for n in sorted {
        guard let route  = routes[n],
              !usbRightTracks.contains(route.trackKey),
              names[route.trackKey] == nil,
              let grp    = route.inputGroup,
              let inNum  = route.inputNumber,
              let grpMap = ioIn[grp] as? [String: Any],
              let inInfo = grpMap["\(inNum)"] as? [String: Any],
              let raw    = inInfo["name"] as? String
        else { continue }
        let s = sanitizeChannelName(raw)
        if !s.isEmpty { names[route.trackKey] = s }
    }

    return names
}

/// Extracts scene and show names from an active_scene path
/// (e.g. "I:/ROCK THE END/LIVE TRIPLE B.snap" → ("LIVE TRIPLE B", "ROCK THE END")).
private func sceneAndShow(from activeScene: String?) -> (scene: String?, show: String?) {
    guard let activeScene, !activeScene.isEmpty else { return (nil, nil) }
    let parts = activeScene
        .replacingOccurrences(of: "\\", with: "/")
        .components(separatedBy: "/")
        .filter { !$0.isEmpty }
    let scene = parts.last.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 }
    let show: String? = parts.count >= 2 && parts[parts.count - 2].count > 2
        ? parts[parts.count - 2]
        : nil
    return (scene, show)
}

// MARK: - File discovery

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
