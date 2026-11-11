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
            ? (suffix.isEmpty ? String(format: "ch%02d-%02d.wav", pair.left, pair.right) : shortFilename(suffix))
            : String(format: "%@ch%02d-%02d\(suffix).wav", prefix, pair.left, pair.right)
        specs.append(OutputSpec(
            kind: .stereo(left: pair.left - 1, right: pair.right - 1),
            url: outputDir.appendingPathComponent(filename),
            trackNames: [channelNames[pair.left] ?? "", channelNames[pair.right] ?? ""]
        ))
    }
    for ch in 0 ..< numChannels where !pairedChannels.contains(ch + 1) {
        let suffix = channelNameSuffix(for: [ch + 1], names: channelNames)
        let filename = useShortFilenames
            ? (suffix.isEmpty ? String(format: "ch%02d.wav", ch + 1) : shortFilename(suffix))
            : String(format: "%@ch%02d\(suffix).wav", prefix, ch + 1)
        specs.append(OutputSpec(
            kind: .mono(ch: ch),
            url: outputDir.appendingPathComponent(filename),
            trackNames: [channelNames[ch + 1] ?? ""]
        ))
    }
    return specs
}

/// Windows device names, unusable as file names even with an extension.
private let windowsReservedNames: Set<String> = Set(
    ["CON", "PRN", "AUX", "NUL"]
        + (1...9).map { "COM\($0)" }
        + (1...9).map { "LPT\($0)" }
)

/// "_Kick" -> "Kick.wav", "_CON" -> "CON_.wav".
private func shortFilename(_ suffix: String) -> String {
    let base = String(suffix.dropFirst())
    if windowsReservedNames.contains(base.uppercased()) {
        return "\(base)_.wav"
    }
    return "\(base).wav"
}

/// Removes silent output files and returns a `SplitResult`.
/// `hasSignal[i]` must align with `specs[i]`.
public func collectSplitResult(
    specs: [OutputSpec],
    hasSignal: [Bool],
    totalFramesWritten: UInt64,
    sampleRate: Double,
    sourceFormat: SourceFormat? = nil,
    elapsedSec: Double = 0,
    bytesRead: UInt64 = 0
) -> SplitResult {
    var keptOutputs: [OutputFile] = []
    var droppedOutputs: [OutputFile] = []
    var keptMonoCount = 0, keptStereoCount = 0
    for (spec, signal) in zip(specs, hasSignal) {
        let file = OutputFile(url: spec.url, trackNames: spec.trackNames,
                              kind: spec.kind, channels: spec.kind.sourceChannels)
        if !signal {
            try? FileManager.default.removeItem(at: spec.url)
            droppedOutputs.append(file)
        } else {
            keptOutputs.append(file)
            switch spec.kind {
            case .mono:   keptMonoCount += 1
            case .stereo: keptStereoCount += 1
            }
        }
    }
    return SplitResult(
        outputs: keptOutputs, dropped: droppedOutputs,
        keptMono: keptMonoCount, keptStereo: keptStereoCount,
        silentSkipped: droppedOutputs.count, totalFrames: totalFramesWritten,
        sampleRate: sampleRate, sourceFormat: sourceFormat,
        elapsedSec: elapsedSec, bytesRead: bytesRead
    )
}
