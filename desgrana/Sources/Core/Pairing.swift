// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

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
