// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Combine
import SwiftUI
import DesgranaCore

// MARK: - State

enum SplitState: Equatable {
    case idle
    case ready(URL)
    case splitting(take: Int, totalTakes: Int, fraction: Double)
    case done(
        channelCount: Int, duration: Double,
        extractedMono: Int, extractedStereo: Int,
        silentMono: Int, silentStereo: Int,
        outputDir: URL
    )
    case error(String)
}

// MARK: - Output row model

struct OutputRow: Identifiable {
    let id: Int  // left channel (or channel number for mono)
    let chLabel: String
    let nameLabel: String
    enum Kind { case stereo(left: Int), monoLinkable(ch: Int), monoLinkablePrev(ch: Int), mono }
    let kind: Kind
}

// MARK: - ViewModel

@MainActor
class SplitViewModel: ObservableObject {
    /// The loaded recording session — single source of truth for all domain state.
    /// Parsing, stereo-pair derivation and progress offsets live in `Session` (Core),
    /// shared verbatim with the C bridge (Qt). This view model only adds UI/platform
    /// concerns: the state machine, preference persistence, and the split task.
    @Published var session = Session()
    @Published var state: SplitState = .idle
    @Published var customOutputDir: URL?
    @Published var shortFilenames: Bool = true
    @Published private(set) var lastMarkers: [(time: Double, name: String)] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        shortFilenames = UserDefaults.standard.object(forKey: "shortFilenames") as? Bool ?? true
        if let path = UserDefaults.standard.string(forKey: "outputDirPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { customOutputDir = url }
        }
        $shortFilenames
            .sink { UserDefaults.standard.set($0, forKey: "shortFilenames") }
            .store(in: &cancellables)
        $customOutputDir
            .sink { UserDefaults.standard.set($0?.path, forKey: "outputDirPath") }
            .store(in: &cancellables)
    }

    // MARK: - Forwarding accessors (keep the view API stable; `session` is the truth)

    var sessionInfo: SessionInfo? { session.sessionInfo }
    var snapInfo: SnapInfo? { session.snapInfo }
    var snapName: String? { session.snapName }
    var wavFiles: [URL] { session.takes }
    var resolvedTakes: [URL] { session.takes }
    var inferredChannels: Int? { session.inferredChannels }
    var fallbackChannelNames: [Int: String] { session.fallbackChannelNames }
    var effectivePairs: [StereoPair] { session.effectivePairs }
    var effectiveChannelNames: [Int: String] { session.effectiveChannelNames }
    var isCustomized: Bool { session.isCustomized }

    var sessionName: String {
        get { session.sessionName }
        set { session.sessionName = newValue }
    }

    func unlinkPair(left: Int) { session.unlinkPair(left: left) }
    func linkChannels(_ left: Int, _ right: Int) { session.linkChannels(left, right) }
    func resetPairs() { session.resetPairs() }

    func defaultOutputDir(for sessionDir: URL) -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let name = sessionName.isEmpty ? sessionDir.lastPathComponent : sessionName
        return desktop.appendingPathComponent(name.replacingOccurrences(of: " ", with: "_"))
    }

    // MARK: - Loading

    func loadSession(url: URL) {
        switch Session.load(input: url) {
        case .ambiguous:
            session = Session()
            lastMarkers = []
            state = .error("This folder contains several WAV files. Drop a single file, or a session folder.")
        case .empty:
            session = Session()
            lastMarkers = []
            state = .error("No WAV takes found in this directory.")
        case .ok(let loaded, let dir):
            session = loaded
            lastMarkers = []
            state = .ready(dir)
        }
    }

    func loadSnap(url: URL) {
        session.loadSnap(url: url)
    }

    // MARK: - Splitting

    /// Applies a progress tick only while a split is still running. Progress callbacks hop
    /// to the main actor as independent tasks, so a late tick can otherwise land after the
    /// final `.done`/`.error` and revert the UI to `.splitting` — guard against that here.
    private func applyProgress(take: Int, totalTakes: Int, fraction: Double) {
        guard case .splitting = state else { return }
        state = .splitting(take: take, totalTakes: totalTakes, fraction: fraction)
    }

    func split(sessionDir: URL) {
        let outputDir = customOutputDir ?? defaultOutputDir(for: sessionDir)

        let pfx: String
        if shortFilenames {
            pfx = ""
        } else {
            let name = sessionName.isEmpty ? sessionDir.lastPathComponent : sessionName
            pfx = name.replacingOccurrences(of: " ", with: "_") + "_"
        }

        let info      = session.sessionInfo
        let pairs     = session.effectivePairs
        let names     = session.effectiveChannelNames
        let shortNames = shortFilenames
        let pairedChs = Set(pairs.flatMap { [$0.left, $0.right] })

        state = .splitting(take: 0, totalTakes: 0, fraction: 0)

        let totalFrames = Double(info?.totalLength ?? 0)
        // framesBeforeTake[N] = total frames already processed before take N starts (1-based).
        let framesBeforeTake = session.frameOffsetsBeforeTakes()

        let capturedTakes = session.takes
        let fallbackCh = session.inferredChannels
        Task.detached { [weak self] in
            do {
                let result = try splitSession(
                    sessionDir: sessionDir,
                    outputDir: outputDir,
                    prefix: pfx,
                    stereoPairs: pairs,
                    channelNames: names,
                    useShortFilenames: shortNames,
                    takes: capturedTakes,
                    markers: info?.markerSamples ?? [],
                    progress: { take, total, framesInTake in
                        let before = framesBeforeTake[take] ?? 0
                        let fraction = totalFrames > 0
                            ? min((before + Double(framesInTake)) / totalFrames, 1.0)
                            : 0
                        Task { @MainActor in
                            self?.applyProgress(take: take, totalTakes: total, fraction: fraction)
                        }
                    }
                )

                // iXML track names, bext and cue (markers) are embedded before `data`
                // at file creation by splitSession.
                if let info, !info.markerSamples.isEmpty {
                    exportMarkers(info, to: outputDir, prefix: pfx)
                    exportMIDIMarkers(info, to: outputDir, prefix: pfx)
                }

                let totalCh = info?.numChannels ?? fallbackCh ?? 0
                let channelCount = totalCh
                let duration = info?.totalDuration
                    ?? (result.sampleRate > 0 ? Double(result.totalFrames) / result.sampleRate : 0)
                let extractedMono = result.keptMono
                let extractedStereo = result.keptStereo
                let silentStereo = pairs.count - extractedStereo
                let monoTrackCount = max(totalCh - pairedChs.count, 0)
                let silentMono = monoTrackCount - extractedMono

                let markerList: [(time: Double, name: String)] = (info?.markerSamples ?? [])
                    .enumerated()
                    .map { i, s in (time: Double(s) / Double(info?.sampleRate ?? 48_000), name: "Marker \(i + 1)") }

                await MainActor.run { [weak self] in
                    self?.lastMarkers = markerList
                    self?.state = .done(
                        channelCount: channelCount,
                        duration: duration,
                        extractedMono: extractedMono,
                        extractedStereo: extractedStereo,
                        silentMono: silentMono,
                        silentStereo: silentStereo,
                        outputDir: outputDir
                    )
                }
            } catch {
                let msg = "\(error)"
                await MainActor.run { [weak self] in
                    self?.state = .error(msg)
                }
            }
        }
    }

    func reset() {
        session = Session()
        state = .idle
        lastMarkers = []
    }
}
