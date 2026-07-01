// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Session

/// The loaded state of one recording session, plus the pure derivations
/// (stereo pairs, channel names, progress offsets) that the frontends need.
///
/// This is the single source of truth shared by the SwiftUI ViewModel and the
/// C bridge (Qt). It holds no UI, persistence, or platform state — only domain
/// data and value-type logic, so it stays testable in isolation and identical
/// across frontends.
public struct Session {
    public var sessionInfo: SessionInfo?
    public var snapInfo: SnapInfo?
    public var snapName: String?
    /// The takes to split, in order (hex session, a single file, or a single WAV in a dir).
    public var takes: [URL]
    /// Channel count read from the first WAV header when there is no SE_LOG.bin.
    public var inferredChannels: Int?
    /// Duration (seconds) read from the first WAV header when there is no SE_LOG.bin.
    public var inferredDuration: Double?
    /// Track names from the WAV (iXML) when there is no snap.
    public var fallbackChannelNames: [Int: String]
    /// Manual pair edits; takes precedence over the snap-derived pairs when non-nil.
    public var userOverridePairs: [StereoPair]?
    public var sessionName: String

    public init(
        sessionInfo: SessionInfo? = nil,
        snapInfo: SnapInfo? = nil,
        snapName: String? = nil,
        takes: [URL] = [],
        inferredChannels: Int? = nil,
        inferredDuration: Double? = nil,
        fallbackChannelNames: [Int: String] = [:],
        userOverridePairs: [StereoPair]? = nil,
        sessionName: String = ""
    ) {
        self.sessionInfo = sessionInfo
        self.snapInfo = snapInfo
        self.snapName = snapName
        self.takes = takes
        self.inferredChannels = inferredChannels
        self.inferredDuration = inferredDuration
        self.fallbackChannelNames = fallbackChannelNames
        self.userOverridePairs = userOverridePairs
        self.sessionName = sessionName
    }

    // MARK: Loading

    public enum Loaded {
        case ok(Session, dir: URL)
        case empty                    // no WAV takes found
        case ambiguous([URL])         // 2+ unrelated WAVs in a folder — caller must refuse
    }

    /// Resolves a dropped/passed input (a session folder, a single WAV, or a folder
    /// with one WAV) into a fully populated `Session`. Looks up SE_LOG and the console
    /// snapshot next to the takes, and recovers channel count / track names from the
    /// WAV header when those files are absent.
    ///
    /// This is the orchestration previously duplicated between `SplitViewModel.loadSession`
    /// and the bridge's `desgrana_probe`.
    public static func load(input: URL) -> Loaded {
        switch resolveSessionTakes(at: input) {
        case .ambiguous(let files):
            return .ambiguous(files)
        case .empty:
            return .empty
        case .ok(let takes):
            guard !takes.isEmpty else { return .empty }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir)
            let isFileInput = exists && !isDir.boolValue
            let dir = isFileInput ? input.deletingLastPathComponent() : input

            let selogURL = seLogCandidates
                .lazy
                .map { dir.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let sessionInfo = selogURL.flatMap { try? parseSELog(at: $0) }

            let snapURL = findConsoleSnapshot(in: dir)
            let snapInfo = snapURL.flatMap { try? parseSnapOrScene(at: $0) }

            // No SE_LOG: recover channel count and duration from the first WAV header.
            let header = sessionInfo == nil ? takes.first.flatMap { probeWavHeader(at: $0) } : nil

            // No snap: fall back to track names embedded in the WAV (iXML).
            let fallbackNames = snapInfo == nil
                ? (takes.first.map { parseIXMLTrackNames(at: $0) } ?? [:])
                : [:]

            var session = Session(
                sessionInfo: sessionInfo,
                snapInfo: snapInfo,
                snapName: snapURL?.lastPathComponent,
                takes: takes,
                inferredChannels: header?.channels,
                inferredDuration: header?.duration,
                fallbackChannelNames: fallbackNames
            )
            session.sessionName = isFileInput
                ? input.deletingPathExtension().lastPathComponent
                : session.bestSessionName(dir: dir)
            return .ok(session, dir: dir)
        }
    }

    /// Parses a single `.snap`/`.scn` file into this session, clearing any manual edits.
    /// Mirrors `SplitViewModel.loadSnap`.
    public mutating func loadSnap(url: URL) {
        guard let info = try? parseSnapOrScene(at: url) else { return }
        snapInfo = info
        snapName = url.lastPathComponent
        userOverridePairs = nil
        if let scene = info.sceneName, !scene.isEmpty {
            sessionName = scene
        }
    }

    // MARK: Derivations

    /// Channel count: from SE_LOG when present, else inferred from the WAV header.
    public var channelCount: Int {
        sessionInfo?.numChannels ?? inferredChannels ?? 0
    }

    /// Pairs derived from the snap.
    /// USB pairs come from the snap config as-is (explicit hardware routing).
    /// LCL pairs are detected from channel names (L/R suffixes); no name means mono.
    /// clink is not used — it reflects live console behaviour, not recording intent.
    public var snapDerivedPairs: [StereoPair] {
        let numCh = channelCount
        guard numCh > 0 else { return [] }

        let usbPairs = filterStereoPairs(snapInfo?.usbStereoPairs ?? [], channelCount: numCh)
        let usbTracks = Set(usbPairs.flatMap { [$0.left, $0.right] })
        let lclPairs = detectStereoPairsFromNames(snapInfo?.channelNames ?? [:], channelCount: numCh)
            .filter { !usbTracks.contains($0.left) }

        return (usbPairs + lclPairs).sorted { $0.left < $1.left }
    }

    /// Pairs used for splitting: manual user override takes precedence, then snap-derived.
    public var effectivePairs: [StereoPair] {
        userOverridePairs ?? snapDerivedPairs
    }

    /// Channel names for splitting: snap names (or WAV fallback names), with _L/_R suffixes
    /// added to both tracks of any USB stereo pair that has been manually unlinked.
    public var effectiveChannelNames: [Int: String] {
        applyUsbUnpairRename(
            names: snapInfo?.channelNames ?? fallbackChannelNames,
            usbPairs: snapInfo?.usbStereoPairs ?? [],
            activePairs: effectivePairs
        )
    }

    public var isCustomized: Bool { userOverridePairs != nil }

    // MARK: Provenance (for the extraction report)

    /// Where an effective stereo pair came from.
    public enum PairOrigin: String {
        case usb    // explicit USB hardware routing in the snap
        case name   // detected from L/R channel names in the snap
        case user   // manual override (CLI --stereo or GUI edit)
    }

    /// Classifies each given pair against the snap: `.usb` if it matches an explicit USB
    /// hardware pair, `.name` if it matches a pair detected from L/R channel names, else
    /// `.user` (a manual link the snap does not account for). Works for pairs supplied by
    /// any frontend (the CLI's effective pairs, or the GUI's live user edits).
    public func classifyPairs(_ pairs: [StereoPair]) -> [(pair: StereoPair, origin: PairOrigin)] {
        let numCh = channelCount
        let usbPairs = filterStereoPairs(snapInfo?.usbStereoPairs ?? [], channelCount: numCh)
        let namedPairs = detectStereoPairsFromNames(
            snapInfo?.channelNames ?? fallbackChannelNames, channelCount: numCh)
        return pairs.map { p in
            if usbPairs.contains(p) { return (p, .usb) }
            if namedPairs.contains(p) { return (p, .name) }
            return (p, .user)
        }
    }

    /// Where a channel's name came from.
    public enum NameSource: String {
        case snap   // console snapshot (.snap / .scn)
        case wav    // embedded iXML track name (no snap)
        case none   // unnamed channel
    }

    public func nameSource(forChannel ch: Int) -> NameSource {
        if snapInfo?.channelNames[ch] != nil { return .snap }
        if fallbackChannelNames[ch] != nil { return .wav }
        return .none
    }

    public mutating func unlinkPair(left: Int) {
        var p = effectivePairs
        p.removeAll { $0.left == left }
        userOverridePairs = p
    }

    public mutating func linkChannels(_ left: Int, _ right: Int) {
        var p = effectivePairs
        p.removeAll { $0.left == left || $0.right == left || $0.left == right || $0.right == right }
        p.append(StereoPair(left: left, right: right))
        userOverridePairs = p.sorted { $0.left < $1.left }
    }

    public mutating func resetPairs() { userOverridePairs = nil }

    // MARK: Naming

    /// Best display name: the snap scene name when present, else a NONAME_ timestamp.
    public func bestSessionName(dir: URL) -> String {
        if let scene = snapInfo?.sceneName, !scene.isEmpty { return scene }
        return Session.nonameFallback()
    }

    public static func nonameFallback(date: Date = Date()) -> String {
        let c = Calendar.current
        return String(format: "NONAME_%02d%02d%02d%02d",
            c.component(.year,  from: date) % 100,
            c.component(.month, from: date),
            c.component(.day,   from: date),
            c.component(.hour,  from: date))
    }

    // MARK: Progress

    /// `[take: framesBefore]`, 1-based take number → total frames already processed
    /// before that take starts. takeSizes are interleaved samples (frames × channels),
    /// so they are divided by the channel count to get frames. Returns empty without SE_LOG.
    public func frameOffsetsBeforeTakes() -> [Int: Double] {
        guard let info = sessionInfo else { return [:] }
        let ch = max(info.numChannels, 1)
        var offsets: [Int: Double] = [:]
        var acc: Double = 0
        for i in 0 ..< info.takeSizes.count {
            offsets[i + 1] = acc
            acc += Double(info.takeSizes[i]) / Double(ch)
        }
        return offsets
    }
}
