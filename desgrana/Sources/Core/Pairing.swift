// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

/// Single source of truth for stereo-pair acceptance: keeps pairs whose channels are
/// in `1...channelCount` and not already claimed, reporting each rejected pair (with a
/// reason) via `onReject`. Returns the accepted pairs and the set of claimed channels.
func acceptStereoPairs(
    _ pairs: [StereoPair],
    channelCount: Int,
    onReject: (StereoPair, String) -> Void = { _, _ in }
) -> (active: [StereoPair], paired: Set<Int>) {
    var seen = Set<Int>()
    var active: [StereoPair] = []
    for pair in pairs {
        guard pair.left  >= 1 && pair.left  <= channelCount,
              pair.right >= 1 && pair.right <= channelCount else {
            onReject(pair, "channel numbers must be in 1...\(channelCount)")
            continue
        }
        var overlap = false
        for ch in [pair.left, pair.right] where !seen.insert(ch).inserted {
            onReject(pair, "channel \(ch) appears in multiple pairs")
            overlap = true
            break
        }
        if !overlap { active.append(pair) }
    }
    return (active, seen)
}

/// Returns only the pairs that are valid for `channelCount`, skipping out-of-range or
/// overlapping entries. Used by the App to filter snap pairs against session channel count.
public func filterStereoPairs(_ pairs: [StereoPair], channelCount: Int) -> [StereoPair] {
    acceptStereoPairs(pairs, channelCount: channelCount).active
}

/// Separators recognised between a stereo base name and its `L`/`R` side.
private let stereoSeparators = ["_", "-", " "]

/// If `left`/`right` share a common `_L`/`-L`/` L` (and `R`) base, returns that
/// base; otherwise nil. Single source of truth for stereo-pair name folding, used
/// by pair detection here, the output filename suffix (`channelNameSuffix`) and the
/// iXML track labels (`stereoLabels`).
func sharedStereoBase(left: String, right: String) -> String? {
    guard !left.isEmpty, !right.isEmpty else { return nil }
    for sep in stereoSeparators where left.hasSuffix("\(sep)L") && right.hasSuffix("\(sep)R") {
        let lb = String(left.dropLast(sep.count + 1))
        if lb == String(right.dropLast(sep.count + 1)), !lb.isEmpty { return lb }
    }
    return nil
}

/// Removes a trailing `_L`/`-L`/` L` (or R) side suffix from a single channel name,
/// recovering its base (e.g. "OH_L" → "OH"). Returns the name unchanged if absent.
func strippedStereoSide(_ s: String, _ side: Character) -> String {
    for sep in stereoSeparators where s.hasSuffix("\(sep)\(side)") { return String(s.dropLast(sep.count + 1)) }
    return s
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
        if sharedStereoBase(left: names[ch] ?? "", right: names[next] ?? "") != nil {
            pairs.append(StereoPair(left: ch, right: next))
            claimed.insert(ch); claimed.insert(next)
        }
    }
    return pairs
}

/// Applies `_L`/`_R` name suffixes to both tracks of any USB stereo pair that is
/// absent from `activePairs` (i.e. manually unlinked). The base name comes from
/// the left track's existing name; if unnamed, `ch<N>` is used as the base.
public func applyUsbUnpairRename(
    names: [Int: String],
    usbPairs: [StereoPair],
    activePairs: [StereoPair]
) -> [Int: String] {
    var result = names
    let activeLeft = Set(activePairs.map(\.left))
    for pair in usbPairs where !activeLeft.contains(pair.left) {
        let base = result[pair.left] ?? "ch\(pair.left)"
        result[pair.left]  = base + "_L"
        result[pair.right] = base + "_R"
    }
    return result
}

/// Validates stereo pairs against `channelCount` for use inside `splitSession`.
/// Prints warnings for rejected pairs and returns the accepted pairs + claimed channel set.
public func validateStereoPairs(
    _ pairs: [StereoPair],
    channelCount: Int
) -> (active: [StereoPair], paired: Set<Int>) {
    acceptStereoPairs(pairs, channelCount: channelCount) { pair, reason in
        fputs("Warning: stereo pair \(pair.left):\(pair.right) skipped — \(reason)\n", stderr)
    }
}
