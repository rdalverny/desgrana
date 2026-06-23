// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Broadcast Wave (bext) metadata
//
// Writes a `bext` chunk into each output WAV. Broadcast Wave metadata is what
// pro field recorders and DAWs expect; a split tool should carry it through.
// When the source take already has a `bext`, its real provenance is preserved
// (timecode, origination date/time, originator). When it does not (the Behringer
// path writes none — only a JUNK pad), we do NOT fabricate a timecode: the time
// fields stay empty, which is the bext convention for "unknown". Either way the
// chunk records that Desgrana processed the file via a CodingHistory line.
// Metadata only — the audio `data` chunk is never touched.

/// bext fixed-field offsets within the chunk payload.
private enum Bext {
    static let originator = 256          // 32 bytes
    static let originatorReference = 288 // 32 bytes
    static let originationDate = 320     // 10 bytes
    static let originationTime = 330     // 8 bytes
    static let timeReference = 338       // 8 bytes (u64 LE)
    static let codingHistory = 602       // variable, to end of chunk
}

/// Provenance fields preserved from a source `bext`, when present.
struct SourceBext {
    let originator: String
    let originatorReference: String
    let originationDate: String
    let originationTime: String
    let timeReferenceLow: UInt32
    let timeReferenceHigh: UInt32
    let codingHistory: String
}

/// Reads the provenance fields from a source take's `bext` chunk, if any.
func parseSourceBext(at url: URL?) -> SourceBext? {
    guard let url, let payload = riffChunk(at: url, id: "bext"), payload.count >= Bext.timeReference + 8 else {
        return nil
    }
    let b = [UInt8](payload)
    func ascii(_ off: Int, _ len: Int) -> String {
        let slice = b[off ..< off + len].prefix { $0 != 0 }
        return String(bytes: slice, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    let history: String
    if b.count > Bext.codingHistory {
        let slice = b[Bext.codingHistory...].prefix { $0 != 0 }
        history = String(bytes: slice, encoding: .ascii) ?? ""
    } else {
        history = ""
    }
    return SourceBext(
        originator: ascii(Bext.originator, 32),
        originatorReference: ascii(Bext.originatorReference, 32),
        originationDate: ascii(Bext.originationDate, 10),
        originationTime: ascii(Bext.originationTime, 8),
        timeReferenceLow: leU32(b, Bext.timeReference),
        timeReferenceHigh: leU32(b, Bext.timeReference + 4),
        codingHistory: history
    )
}

/// ASCII bytes of `s` truncated/zero-padded to exactly `len` bytes.
private func fixedField(_ s: String, _ len: Int) -> Data {
    var bytes = Array(s.utf8.prefix(len))
    bytes.append(contentsOf: repeatElement(0, count: len - bytes.count))
    return Data(bytes)
}

/// Builds the bext payload (602 fixed bytes + CodingHistory).
func bextPayload(source: SourceBext?, sampleRate: Int) -> Data {
    var d = Data()
    d.append(fixedField("", 256))                                   // Description
    d.append(fixedField(source?.originator ?? "Desgrana", 32))      // Originator
    d.append(fixedField(source?.originatorReference ?? "", 32))     // OriginatorReference
    d.append(fixedField(source?.originationDate ?? "", 10))         // OriginationDate
    d.append(fixedField(source?.originationTime ?? "", 8))          // OriginationTime
    d.appendLE(source?.timeReferenceLow ?? 0)                       // TimeReference low
    d.appendLE(source?.timeReferenceHigh ?? 0)                      // TimeReference high
    d.appendLE(UInt16(1))                                          // bext version 1
    d.append(Data(count: 64))                                       // UMID
    d.append(Data(count: 10))                                       // loudness (v2, unused)
    d.append(Data(count: 180))                                      // Reserved
    d.append(Data(codingHistory(sampleRate: sampleRate, source: source).utf8))
    return d
}

/// Appends Desgrana's processing step to the source CodingHistory (BWF convention:
/// each tool in the chain appends its own CRLF-terminated line). Prior history is
/// preserved; only our line is added.
private func codingHistory(sampleRate: Int, source: SourceBext?) -> String {
    var fields = ["A=PCM"]
    if sampleRate > 0 { fields.append("F=\(sampleRate)") }
    fields.append("T=Desgrana \(BuildInfo.version) (\(BuildInfo.gitSHA.prefix(10)))")
    let ours = fields.joined(separator: ",")

    let prior = (source?.codingHistory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return prior.isEmpty ? ours + "\r\n" : prior + "\r\n" + ours + "\r\n"
}

/// Writes a `bext` chunk into each output WAV, preserving the source take's
/// broadcast metadata when present.
public func writeBextChunks(to outputs: [OutputFile], source: URL?, sampleRate: Int) {
    let src = parseSourceBext(at: source)
    let payload = bextPayload(source: src, sampleRate: sampleRate)
    for file in outputs {
        appendRIFFChunk(to: file.url, id: "bext", payload: payload)
    }
}
