// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - iXML track names
//
// Field recorders (Sound Devices, Zoom F-series, Tascam) embed an `iXML` chunk in the WAV
// with a `<BWFXML><TRACK_LIST>` carrying a `<NAME>` per channel — the in-file analogue of
// the Wing `.snap`. Used by the "other recorder" fallback to name tracks instead of
// numbering them; existing L/R-suffix pairing then applies on top.
//
// Parsed with a light regex pass rather than XMLParser, which lives in FoundationXML on
// Linux (not in the Qt link / .deb), and would drag libxml2 into the build for a tiny
// feature. The iXML TRACK_LIST is a flat, known structure, so targeted extraction is fine.
// Known limits (low risk for real recorders): numeric entities (`&#nnn;`), CDATA and
// non-UTF8 encodings are not handled — extend `decodeXMLEntities` / the byte decode if a
// real-world file needs it.

private func ixmlRegex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
}

private func ixmlFirstGroup(_ pattern: String, in s: String) -> String? {
    guard let re = ixmlRegex(pattern) else { return nil }
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: range), let g = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[g])
}

private func ixmlAllGroups(_ pattern: String, in s: String) -> [String] {
    guard let re = ixmlRegex(pattern) else { return [] }
    let range = NSRange(s.startIndex..., in: s)
    return re.matches(in: s, range: range).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
}

private func decodeXMLEntities(_ s: String) -> String {
    decodeNumericEntities(s)
     .replacingOccurrences(of: "&lt;", with: "<")
     .replacingOccurrences(of: "&gt;", with: ">")
     .replacingOccurrences(of: "&quot;", with: "\"")
     .replacingOccurrences(of: "&apos;", with: "'")
     .replacingOccurrences(of: "&amp;", with: "&")   // last, to avoid double-decoding
}

/// Decodes numeric character references `&#nnn;` (decimal) and `&#xHH;` (hex).
/// Invalid or out-of-range references are left untouched.
private func decodeNumericEntities(_ s: String) -> String {
    guard s.contains("&#"), let re = ixmlRegex(#"&#(x?)([0-9A-Fa-f]+);"#) else { return s }
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let isHex = ns.substring(with: m.range(at: 1)) == "x"
        let digits = ns.substring(with: m.range(at: 2))
        if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
            out.append(Character(scalar))
        } else {
            out += ns.substring(with: m.range)   // leave invalid references as-is
        }
        last = m.range.location + m.range.length
    }
    out += ns.substring(with: NSRange(location: last, length: ns.length - last))
    return out
}

/// Reads per-channel track names from the WAV's `iXML` chunk, when present. Returns `[:]`
/// if absent. Maps `<INTERLEAVE_INDEX>` (1-based position in the interleaved file = our
/// channel number) to `<NAME>`, falling back to `<CHANNEL_INDEX>` then to the track order.
public func parseIXMLTrackNames(at url: URL) -> [Int: String] {
    guard let payload = riffChunk(at: url, id: "iXML") else { return [:] }
    var bytes = [UInt8](payload)
    while bytes.last == 0 { bytes.removeLast() }      // iXML payloads are often NUL-padded
    guard let xml = String(bytes: bytes, encoding: .utf8) else { return [:] }
    return ixmlTrackNames(fromXML: xml)
}

/// Parses the `<TRACK_LIST>` of an iXML document into [channel: name]. Split out from the
/// file reader so it is unit-testable without building a WAV. Internal on purpose.
func ixmlTrackNames(fromXML xml: String) -> [Int: String] {
    guard let list = ixmlFirstGroup(#"<TRACK_LIST\b[^>]*>(.*)</TRACK_LIST>"#, in: xml) else { return [:] }
    var names: [Int: String] = [:]
    var order = 0
    for track in ixmlAllGroups(#"<TRACK\b[^>]*>(.*?)</TRACK>"#, in: list) {
        order += 1
        guard let rawName = ixmlFirstGroup(#"<NAME\b[^>]*>(.*?)</NAME>"#, in: track) else { continue }
        let name = decodeXMLEntities(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        let index = ixmlFirstGroup(#"<INTERLEAVE_INDEX\b[^>]*>\s*(\d+)"#, in: track).flatMap { Int($0) }
            ?? ixmlFirstGroup(#"<CHANNEL_INDEX\b[^>]*>\s*(\d+)"#, in: track).flatMap { Int($0) }
            ?? order
        names[index] = name
    }
    return names
}

// MARK: - iXML write
//
// Mirror of the reader above: embeds an `iXML` chunk carrying per-channel track
// names into each output WAV, so the names survive a file rename and round-trip
// back through `parseIXMLTrackNames`. Metadata-only — the audio `data` chunk is
// never touched (see RIFFWrite.swift).

/// Escapes the five XML predefined entities for safe inclusion in element text.
func encodeXMLEntities(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")    // first, to avoid double-encoding
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}

/// Derives the two channel labels for a stereo file from its raw channel names.
/// When both sides share an `_L`/`-L`/` L` (and R) base, collapses to
/// `("<base> L", "<base> R")`. When both are named but unrelated, keeps each name
/// verbatim. When only one side is named, derives `L`/`R` from it. Returns nil if
/// neither side has a name.
func stereoLabels(left: String, right: String) -> (String, String)? {
    if let base = sharedStereoBase(left: left, right: right) {
        return ("\(base) L", "\(base) R")           // shared base → collapse
    }
    if !left.isEmpty, !right.isEmpty {
        return (left, right)                          // distinct names → preserve both
    }
    let base = left.isEmpty ? strippedStereoSide(right, "R") : strippedStereoSide(left, "L")
    guard !base.isEmpty else { return nil }
    return ("\(base) L", "\(base) R")
}

/// Builds a minimal BWFXML document for a file's track names (1 entry = mono,
/// 2 = stereo L/R). Returns nil when there is no name worth recording.
func ixmlDocument(forTrackNames names: [String]) -> String? {
    let labels: [String]
    switch names.count {
    case 1 where !names[0].isEmpty: labels = [names[0]]
    case 2:
        guard let (l, r) = stereoLabels(left: names[0], right: names[1]) else { return nil }
        labels = [l, r]
    default: return nil
    }
    let tracks = labels.enumerated().map { i, name in
        "<TRACK><CHANNEL_INDEX>\(i + 1)</CHANNEL_INDEX><INTERLEAVE_INDEX>\(i + 1)</INTERLEAVE_INDEX>"
            + "<NAME>\(encodeXMLEntities(name))</NAME></TRACK>"
    }.joined()
    return #"<?xml version="1.0" encoding="UTF-8"?>"#
        + "<BWFXML><IXML_VERSION>1.61</IXML_VERSION>"
        + "<TRACK_LIST><TRACK_COUNT>\(labels.count)</TRACK_COUNT>\(tracks)</TRACK_LIST></BWFXML>"
}
