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
    s.replacingOccurrences(of: "&lt;", with: "<")
     .replacingOccurrences(of: "&gt;", with: ">")
     .replacingOccurrences(of: "&quot;", with: "\"")
     .replacingOccurrences(of: "&apos;", with: "'")
     .replacingOccurrences(of: "&#39;", with: "'")
     .replacingOccurrences(of: "&amp;", with: "&")   // last, to avoid double-decoding
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
