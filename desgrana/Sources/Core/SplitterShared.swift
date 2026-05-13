// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

/// Builds the list of output track specs (filenames + kinds) from stereo pairs and
/// mono channels. Platform-independent; does not open any files.
public func buildOutputSpecs(
    activePairs: [StereoPair],
    pairedChannels: Set<Int>,
    numChannels: Int,
    channelNames: [Int: String],
    outputDir: URL,
    prefix: String,
    useShortFilenames: Bool
) -> [OutputSpec] {
    var specs: [OutputSpec] = []
    for pair in activePairs {
        let suffix = channelNameSuffix(for: [pair.left, pair.right], names: channelNames)
        let filename = useShortFilenames
            ? (suffix.isEmpty ? String(format: "ch%02d-%02d.wav", pair.left, pair.right) : "\(suffix.dropFirst()).wav")
            : String(format: "%@ch%02d-%02d\(suffix).wav", prefix, pair.left, pair.right)
        specs.append(OutputSpec(
            kind: .stereo(left: pair.left - 1, right: pair.right - 1),
            url: outputDir.appendingPathComponent(filename)
        ))
    }
    for ch in 0 ..< numChannels where !pairedChannels.contains(ch + 1) {
        let suffix = channelNameSuffix(for: [ch + 1], names: channelNames)
        let filename = useShortFilenames
            ? (suffix.isEmpty ? String(format: "ch%02d.wav", ch + 1) : "\(suffix.dropFirst()).wav")
            : String(format: "%@ch%02d\(suffix).wav", prefix, ch + 1)
        specs.append(OutputSpec(
            kind: .mono(ch: ch),
            url: outputDir.appendingPathComponent(filename)
        ))
    }
    return specs
}

/// Removes silent output files and returns a `SplitResult`.
/// `hasSignal[i]` must align with `specs[i]`.
public func collectSplitResult(
    specs: [OutputSpec],
    hasSignal: [Bool],
    totalFramesWritten: UInt64,
    sampleRate: Double
) -> SplitResult {
    var keptURLs: [URL] = []
    var silentCount = 0
    var keptMonoCount = 0, keptStereoCount = 0
    for (spec, signal) in zip(specs, hasSignal) {
        if !signal {
            try? FileManager.default.removeItem(at: spec.url)
            silentCount += 1
        } else {
            keptURLs.append(spec.url)
            switch spec.kind {
            case .mono:   keptMonoCount += 1
            case .stereo: keptStereoCount += 1
            }
        }
    }
    return SplitResult(
        urls: keptURLs, keptMono: keptMonoCount, keptStereo: keptStereoCount,
        silentSkipped: silentCount, totalFrames: totalFramesWritten, sampleRate: sampleRate
    )
}
