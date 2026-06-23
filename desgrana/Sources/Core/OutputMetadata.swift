// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Output metadata chunks (written before `data` by WAVWriter)
//
// Builds the bext / iXML / cue chunks for each output file in one place, so both
// splitter backends embed identical metadata at file-creation time. The source
// `bext` is parsed once; iXML is per-file (track names); cue (markers) is session
// global and shared by every output.

/// Metadata chunks to embed in each output, aligned with `specs`. `bext` is always
/// present (synthesized when the source has none); `iXML` only when the file has a
/// named channel; `cue ` only when there are markers.
public func outputMetadata(
    for specs: [OutputSpec],
    source: URL?,
    sampleRate: Int,
    markers: [UInt32]
) -> [[(id: String, payload: Data)]] {
    let bext = bextPayload(source: parseSourceBext(at: source), sampleRate: sampleRate)
    let cue: Data? = markers.isEmpty ? nil : cuePayload(markers)
    return specs.map { spec in
        var chunks: [(id: String, payload: Data)] = [("bext", bext)]
        if let xml = ixmlDocument(forTrackNames: spec.trackNames) {
            chunks.append(("iXML", Data(xml.utf8)))
        }
        if let cue { chunks.append(("cue ", cue)) }
        return chunks
    }
}
