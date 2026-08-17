// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Wing snapshot (.snap) parser
//
// A Wing snapshot is a JSON file produced by the Behringer Wing console.
// Documented in "WING Remote Protocols" by Patrick-Gilles Maillot.
//
// A recorded WAV track resolves to a source input two ways:
//  - Card routing (WLive / SD): track N comes from ae_data.io.out.CRD.N.{grp,in}.
//    Used when the snap has an io.out.CRD section.
//  - Channel strips (ae_data.ch): track N follows USB input numbers for USB
//    stereo, channel numbers otherwise. Used when there is no CRD.
//
// Names key on WAV track number. Card routing names every routed track, so both
// halves of a stereo pair share a name; channel strips name only the pair's left.

/// JSON keys and enumerated values used across the Wing snapshot.
private enum SnapKey {
    static let card   = "CRD"   // card recorder output routing group (ae_data.io.out.CRD)
    static let usb    = "USB"
    static let off    = "OFF"   // "no source" placeholder for an unrouted output
    static let group  = "grp"
    static let input  = "in"
    static let name   = "name"
    static let mode   = "mode"
}

/// Input modes that make an input occupy two consecutive slots (a stereo pair).
private enum SnapMode {
    static let stereo   = "ST"
    static let midSide  = "M/S"

    static func isStereo(_ mode: String?) -> Bool {
        mode == stereo || mode == midSide
    }
}

public struct SnapInfo {
    /// Hardware stereo source pairs (explicit routing), 1-indexed.
    public let hwStereoPairs: [StereoPair]
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

    let io    = ae["io"] as? [String: Any]
    let ioIn  = io.flatMap { $0["in"] as? [String: Any] }
    let ioOut = io.flatMap { $0["out"] as? [String: Any] }
    let (sceneName, showName) = sceneAndShow(from: dict["active_scene"] as? String)

    // The card routing decides which input lands on each recorded track.
    if let routing = cardRouting(ioOut) {
        let names = cardNames(routing: routing, ioIn: ioIn)
        let pairs = cardStereoPairs(routing: routing, ioIn: ioIn)
        return SnapInfo(hwStereoPairs: pairs, channelNames: names, sceneName: sceneName, showName: showName)
    }

    // Otherwise, derive names and pairs from the channel strips.
    let sorted   = ch.keys.compactMap(Int.init).sorted()
    let usbIO    = ioIn?[SnapKey.usb] as? [String: Any]
    let routes   = channelRoutes(channels: ch, sorted: sorted, usbIO: usbIO)
    let usbPairs = collectUsbPairs(sorted: sorted, routes: routes)
    let names    = collectNames(sorted: sorted, routes: routes, usbPairs: usbPairs, ioIn: ioIn)

    return SnapInfo(hwStereoPairs: usbPairs, channelNames: names, sceneName: sceneName, showName: showName)
}

// MARK: - Card recorder routing
//
// ae_data.io.out.CRD maps each card output (= recorded WAV track) to a source
// {grp, in}; names and stereo linking come from ae_data.io.in.[grp][in].

/// A physical source feeding one card output.
private struct CardSource {
    let group: String
    let input: Int
}

/// Reads ae_data.io.out.CRD into [trackNumber: CardSource].
/// Track number = card output number.
/// Returns nil when the snap has no card routing (fall back to the channel-strip path).
/// Unrouted outputs (grp == "OFF") are dropped: they carry no source and stay unnamed.
private func cardRouting(_ ioOut: [String: Any]?) -> [Int: CardSource]? {
    guard let crd = ioOut?[SnapKey.card] as? [String: Any] else { return nil }

    var result: [Int: CardSource] = [:]
    for (key, value) in crd {
        guard let track = Int(key),
              let entry = value as? [String: Any],
              let group = entry[SnapKey.group] as? String,
              group != SnapKey.off,
              let input = entry[SnapKey.input] as? Int
        else { continue }
        result[track] = CardSource(group: group, input: input)
    }
    return result
}

/// Looks up the input dictionary ae_data.io.in.[grp][in] for a card source.
private func inputInfo(for src: CardSource, ioIn: [String: Any]?) -> [String: Any]? {
    (ioIn?[src.group] as? [String: Any])?["\(src.input)"] as? [String: Any]
}

/// Names each track from its source input, keyed by WAV track number.
/// Both halves of a stereo pair name the same input; the combined output
/// file collapses the two identical names into one.
/// A source with no io.in name (an unnamed input, or a bus like MAIN that lives outside
/// io.in) is labelled by its routing group and index, e.g. MAIN 1 for the main bus L leg.
private func cardNames(routing: [Int: CardSource], ioIn: [String: Any]?) -> [Int: String] {
    var names: [Int: String] = [:]
    for (track, src) in routing {
        if let raw = inputInfo(for: src, ioIn: ioIn)?[SnapKey.name] as? String,
           case let named = sanitizeChannelName(raw), !named.isEmpty {
            names[track] = named
        } else {
            names[track] = sanitizeChannelName("\(src.group) \(src.input)")
        }
    }
    return names
}

/// Pairs two consecutive card outputs whose sources are (grp, in)
/// and (grp, in+1) of a stereo input.
/// Group-agnostic — USB, LCL, AES, any stereo input.
private func cardStereoPairs(routing: [Int: CardSource], ioIn: [String: Any]?) -> [StereoPair] {
    var pairs: [StereoPair] = []
    var claimed = Set<Int>()

    for track in routing.keys.sorted() {
        guard !claimed.contains(track), let left = routing[track] else { continue }

        // The source input must be a stereo input (occupies two consecutive slots).
        let mode = inputInfo(for: left, ioIn: ioIn)?[SnapKey.mode] as? String
        guard SnapMode.isStereo(mode) else { continue }

        // The next card output must carry the right half of the same stereo input.
        guard let right = routing[track + 1],
              right.group == left.group,
              right.input == left.input + 1
        else { continue }

        pairs.append(StereoPair(left: track, right: track + 1))
        claimed.insert(track)
        claimed.insert(track + 1)
    }
    return pairs
}

// MARK: - Helpers

/// Parsed data for one Wing channel, keyed by channel number.
private struct ChannelRoute {
    let trackKey: Int       // 1-based WAV track number (= USB input for USB stereo, channel number otherwise)
    let isUsbStereo: Bool
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
        let name  = info["name"] as? String
        let grp   = conn?["grp"] as? String
        let inNum = conn?["in"] as? Int
        if grp == SnapKey.usb,
           let usbIn = inNum,
           let mode  = (usbIO?["\(usbIn)"] as? [String: Any])?[SnapKey.mode] as? String,
           SnapMode.isStereo(mode) {
            result[n] = ChannelRoute(trackKey: usbIn, isUsbStereo: true,
                                     name: name, inputGroup: grp, inputNumber: inNum)
        } else {
            result[n] = ChannelRoute(trackKey: n, isUsbStereo: false,
                                     name: name, inputGroup: grp, inputNumber: inNum)
        }
    }
    return result
}

/// Collects USB stereo pairs. Each USB stereo channel occupies two consecutive WAV tracks.
/// Claimed set prevents duplicates when multiple Wing channels share the same USB input.
private func collectUsbPairs(sorted: [Int], routes: [Int: ChannelRoute]) -> [StereoPair] {
    var pairs: [StereoPair] = []
    var claimed = Set<Int>()
    for n in sorted {
        guard let route = routes[n], route.isUsbStereo,
              !claimed.contains(route.trackKey) else { continue }
        let pair = StereoPair(left: route.trackKey, right: route.trackKey + 1)
        pairs.append(pair)
        claimed.insert(route.trackKey)
        claimed.insert(route.trackKey + 1)
    }
    return pairs
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
    firstFile(in: dir, withExtension: "snap")
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
