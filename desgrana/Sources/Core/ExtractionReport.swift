// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Extraction report
//
// A machine-readable (JSON) account of one extraction: what came in (formats,
// takes, metadata sources), what was decided (stereo pairs and channel names with
// their provenance), what came out (files, sizes, kept vs silent), and the markers
// carried over. Built in Core so the CLI (--json) and both GUIs share one schema.
//
// The schema is versioned (`schema`); bump it on any breaking change so consumers
// can detect the shape they are reading.

public struct ExtractionReport: Codable {
    public var schema: Int = 1
    public var tool: Tool
    public var generatedAt: String        // ISO-8601
    public var dryRun: Bool
    public var input: Input
    public var decisions: Decisions
    public var outputs: Outputs?          // nil in dry-run
    public var plannedOutputs: [FileEntry]?   // dry-run only
    public var ignored: Ignored?          // nil in dry-run
    public var markers: Markers

    public struct Tool: Codable {
        public var name: String
        public var version: String
    }

    public struct Input: Codable {
        public var sessionDir: String
        public var isSingleFile: Bool
        public var format: Format?
        public var metadataSources: MetadataSources
        public var takes: [Take]
        public var expectedTakes: Int
        public var foundTakes: Int
    }

    public struct Format: Codable {
        public var channels: Int
        public var sampleRate: Int
        public var bitsPerSample: Int
        public var isFloat: Bool
    }

    public struct MetadataSources: Codable {
        public var seLog: Bool
        public var snap: Snap?
        public var ixmlNames: Bool
    }

    public struct Snap: Codable {
        public var name: String
        public var kind: String           // "wing" | "x32"
        public var sceneName: String?
    }

    public struct Take: Codable {
        public var file: String
        public var foundOnDisk: Bool
        public var sizeBytes: Int?
        public var frames: Int?
        public var durationSec: Double?
    }

    public struct Decisions: Codable {
        public var prefix: String
        public var shortNames: Bool
        public var outputDir: String
        public var stereoPairs: [Pair]
        public var channelNames: [ChannelName]
    }

    public struct Pair: Codable {
        public var left: Int
        public var right: Int
        public var origin: String         // "usb" | "name" | "user"
    }

    public struct ChannelName: Codable {
        public var channel: Int
        public var name: String
        public var source: String         // "snap" | "wav" | "none"
    }

    public struct Outputs: Codable {
        public var files: [FileEntry]
        public var keptMono: Int
        public var keptStereo: Int
        public var sampleRate: Int
        public var totalFrames: Int
        public var durationSec: Double
    }

    public struct FileEntry: Codable {
        public var file: String
        public var kind: String           // "mono" | "stereo"
        public var channels: [Int]        // 1-indexed source channels
        public var trackNames: [String]
        public var sizeBytes: Int?
    }

    public struct Ignored: Codable {
        public var silentTracks: [FileEntry]
    }

    public struct Markers: Codable {
        public var count: Int
        public var items: [Marker]
        public var sidecars: Sidecars
    }

    public struct Marker: Codable {
        public var index: Int
        public var sample: Int
        public var timeSec: Double
        public var name: String
    }

    public struct Sidecars: Codable {
        public var csv: String?
        public var txt: String?
        public var mid: String?
    }

    /// Pretty-printed, key-sorted JSON. Stable output for diffing and agent parsing.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Builder

/// Assembles an `ExtractionReport` from a loaded session and the outcome.
///
/// Pass `result` for a real extraction; pass `plannedSpecs` (and leave `result`
/// nil) for a dry-run, which fills `plannedOutputs` instead of `outputs`/`ignored`.
public func buildExtractionReport(
    session: Session,
    sessionDir: URL,
    outputDir: URL,
    prefix: String,
    shortNames: Bool,
    isSingleFile: Bool,
    pairs: [StereoPair],
    channelNames: [Int: String],
    result: SplitResult?,
    plannedSpecs: [OutputSpec]? = nil,
    format: SourceFormat? = nil,
    toolVersion: String = BuildInfo.version,
    now: Date = Date()
) -> ExtractionReport {
    let info = session.sessionInfo
    let dryRun = (result == nil)

    // Source format: from the real split when available, else the probed/dry-run value.
    let srcFormat = result?.sourceFormat ?? format
    let reportFormat = srcFormat.map {
        ExtractionReport.Format(channels: $0.channels, sampleRate: $0.sampleRate,
                                bitsPerSample: $0.bitsPerSample, isFloat: $0.isFloat)
    }

    // Metadata sources.
    let snapMeta: ExtractionReport.Snap? = session.snapInfo.map { snap in
        let kind = (session.snapName?.lowercased().hasSuffix(".scn") ?? false) ? "x32" : "wing"
        return ExtractionReport.Snap(name: session.snapName ?? "", kind: kind, sceneName: snap.sceneName)
    }
    let ixmlNames = session.snapInfo == nil && !session.fallbackChannelNames.isEmpty
    let metaSources = ExtractionReport.MetadataSources(
        seLog: info != nil, snap: snapMeta, ixmlNames: ixmlNames)

    // Takes: SE_LOG gives expected count + per-take sizes; recoup with what is on disk.
    let takes = buildTakeEntries(session: session, info: info)
    let foundTakes = takes.filter { $0.foundOnDisk }.count
    let expectedTakes = info?.numTakes ?? session.takes.count

    let input = ExtractionReport.Input(
        sessionDir: sessionDir.path,
        isSingleFile: isSingleFile,
        format: reportFormat,
        metadataSources: metaSources,
        takes: takes,
        expectedTakes: expectedTakes,
        foundTakes: foundTakes
    )

    // Decisions: pairs + names with provenance.
    let reportPairs = session.classifyPairs(pairs).map {
        ExtractionReport.Pair(left: $0.pair.left, right: $0.pair.right, origin: $0.origin.rawValue)
    }
    let names = channelNames.keys.sorted().map { ch in
        ExtractionReport.ChannelName(
            channel: ch, name: channelNames[ch] ?? "",
            source: session.nameSource(forChannel: ch).rawValue)
    }
    let decisions = ExtractionReport.Decisions(
        prefix: prefix, shortNames: shortNames, outputDir: outputDir.path,
        stereoPairs: reportPairs, channelNames: names)

    // Markers (identical for real and dry-run: they come from SE_LOG, not the audio pass).
    let markers = buildMarkers(info: info, outputDir: outputDir, prefix: prefix, dryRun: dryRun)

    var report = ExtractionReport(
        tool: ExtractionReport.Tool(name: "desgrana", version: toolVersion),
        generatedAt: iso8601(now),
        dryRun: dryRun,
        input: input,
        decisions: decisions,
        outputs: nil,
        plannedOutputs: nil,
        ignored: nil,
        markers: markers
    )

    if let result {
        let files = result.outputs.map { fileEntry(from: $0) }
        let dropped = result.dropped.map { fileEntry(from: $0) }
        let sr = Int(result.sampleRate)
        report.outputs = ExtractionReport.Outputs(
            files: files, keptMono: result.keptMono, keptStereo: result.keptStereo,
            sampleRate: sr, totalFrames: Int(result.totalFrames),
            durationSec: sr > 0 ? Double(result.totalFrames) / result.sampleRate : 0)
        report.ignored = ExtractionReport.Ignored(silentTracks: dropped)
    } else if let plannedSpecs {
        report.plannedOutputs = plannedSpecs.map { fileEntry(from: $0) }
    }

    return report
}

// MARK: - Builder helpers

private func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: date)
}

private func fileSizeBytes(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
}

private func fileEntry(from f: OutputFile) -> ExtractionReport.FileEntry {
    ExtractionReport.FileEntry(
        file: f.url.lastPathComponent,
        kind: f.kind.isStereo ? "stereo" : "mono",
        channels: f.channels,
        trackNames: f.trackNames,
        sizeBytes: fileSizeBytes(f.url))
}

private func fileEntry(from spec: OutputSpec) -> ExtractionReport.FileEntry {
    ExtractionReport.FileEntry(
        file: spec.url.lastPathComponent,
        kind: spec.kind.isStereo ? "stereo" : "mono",
        channels: spec.kind.sourceChannels,
        trackNames: spec.trackNames,
        sizeBytes: nil)
}

/// One entry per expected take (from SE_LOG), recouped with the WAVs on disk.
/// Without SE_LOG, one entry per found take.
private func buildTakeEntries(session: Session, info: SessionInfo?) -> [ExtractionReport.Take] {
    // hex (lowercased, no extension) → on-disk URL
    var foundByHex: [String: URL] = [:]
    for url in session.takes {
        foundByHex[url.deletingPathExtension().lastPathComponent.lowercased()] = url
    }

    guard let info else {
        // No SE_LOG: just the found takes, size from disk.
        return session.takes.map { url in
            ExtractionReport.Take(
                file: url.lastPathComponent, foundOnDisk: true,
                sizeBytes: fileSizeBytes(url), frames: nil, durationSec: nil)
        }
    }

    let ch = max(info.numChannels, 1)
    let sr = Double(info.sampleRate)
    return (0 ..< info.numTakes).map { i in
        let hex = String(format: "%08x", i + 1)
        let url = foundByHex[hex]
        let frames = i < info.takeSizes.count ? Int(info.takeSizes[i]) / ch : nil
        let duration = (frames != nil && sr > 0) ? Double(frames!) / sr : nil
        return ExtractionReport.Take(
            file: url?.lastPathComponent ?? "\(hex).wav",
            foundOnDisk: url != nil,
            sizeBytes: url.flatMap(fileSizeBytes),
            frames: frames,
            durationSec: duration)
    }
}

private func buildMarkers(
    info: SessionInfo?, outputDir: URL, prefix: String, dryRun: Bool
) -> ExtractionReport.Markers {
    let samples = info?.markerSamples ?? []
    let sr = Double(info?.sampleRate ?? 0)
    let items = samples.enumerated().map { i, s in
        ExtractionReport.Marker(
            index: i + 1, sample: Int(s),
            timeSec: sr > 0 ? Double(s) / sr : 0,
            name: "Marker \(i + 1)")
    }

    // Sidecars are written by the caller after the split; report them when present.
    // In dry-run nothing is written, so leave them nil.
    func sidecar(_ ext: String) -> String? {
        guard !dryRun, !samples.isEmpty else { return nil }
        let url = outputDir.appendingPathComponent("\(prefix)markers.\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }
    let sidecars = ExtractionReport.Sidecars(csv: sidecar("csv"), txt: sidecar("txt"), mid: sidecar("mid"))

    return ExtractionReport.Markers(count: samples.count, items: items, sidecars: sidecars)
}
