// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Combine
import SwiftUI
import DesgranaCore
import DesgranaCoreMac

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
    @Published var state: SplitState = .idle
    @Published var sessionInfo: SessionInfo?
    @Published var snapInfo: SnapInfo?
    @Published var snapName: String?
    @Published var wavFiles: [URL] = []
    @Published var sessionName: String = ""
    @Published var customPairs: [StereoPair]?
    @Published var customOutputDir: URL?
    @Published var shortFilenames: Bool = false
    @Published private(set) var lastMarkers: [(time: Double, name: String)] = []
    private(set) var outputBits: UInt32 = 32
    private var cancellables = Set<AnyCancellable>()

    init() {
        shortFilenames = UserDefaults.standard.bool(forKey: "shortFilenames")
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

    /// Stereo pairs to use for splitting: custom overrides if set, otherwise snap pairs
    /// filtered to the session's channel count.
    var effectivePairs: [StereoPair] {
        if let custom = customPairs { return custom }
        let numCh = sessionInfo?.numChannels ?? 0
        let raw = snapInfo?.stereoPairs ?? []
        return numCh > 0 ? filterStereoPairs(raw, channelCount: numCh) : raw
    }

    var isCustomized: Bool { customPairs != nil }

    func unlinkPair(left: Int) {
        var p = effectivePairs
        p.removeAll { $0.left == left }
        customPairs = p
    }

    func linkChannels(_ left: Int, _ right: Int) {
        var p = effectivePairs
        p.removeAll { $0.left == left || $0.right == left || $0.left == right || $0.right == right }
        p.append(StereoPair(left: left, right: right))
        customPairs = p.sorted { $0.left < $1.left }
    }

    func resetPairs() { customPairs = nil }

    /// Returns the best human-readable name for the session, in priority order:
    /// snap sceneName → SE_LOG name (if not a bare hex timestamp) → folder name.
    func bestSessionName(sessionDir: URL) -> String {
        if let scene = snapInfo?.sceneName, !scene.isEmpty { return scene }
        if let name = sessionInfo?.sessionName, !name.isEmpty,
           name.range(of: #"^[0-9A-F]{8}$"#, options: .regularExpression) == nil {
            return name
        }
        return sessionDir.lastPathComponent
    }

    func defaultOutputDir(for sessionDir: URL) -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let name = sessionName.isEmpty ? sessionDir.lastPathComponent : sessionName
        return desktop.appendingPathComponent(name.replacingOccurrences(of: " ", with: "_"))
    }

    func loadSession(url: URL) {
        let selog = ["SE_LOG.BIN", "se_log.bin", "SE_LOG.bin"]
            .lazy
            .map { url.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        sessionInfo = selog.flatMap { try? parseSELog(at: $0) }

        if let snapURL = findSnap(in: url) {
            snapInfo = try? parseSnap(at: snapURL)
            snapName = snapURL.lastPathComponent
        } else {
            snapInfo = nil
            snapName = nil
        }
        customPairs = nil

        wavFiles = findWavTakes(in: url)
        if let bits = wavBitDepth(in: url), [16, 24, 32].contains(bits) {
            outputBits = bits
        }
        sessionName = bestSessionName(sessionDir: url)
        if wavFiles.isEmpty {
            state = .error("No WAV takes found in this directory.")
        } else {
            state = .ready(url)
        }
    }

    func loadSnap(url: URL) {
        if let info = try? parseSnap(at: url) {
            snapInfo = info
            snapName = url.lastPathComponent
            customPairs = nil
            // Upgrade session name if snap knows better and user hasn't manually changed it
            if let scene = info.sceneName, !scene.isEmpty {
                let looksAutoGenerated = sessionName.isEmpty
                    || sessionName.range(of: #"^[0-9A-F]{8}$"#, options: .regularExpression) != nil
                if looksAutoGenerated { sessionName = scene }
            }
        }
    }

    func clearSnap() {
        snapInfo = nil
        snapName = nil
        customPairs = nil
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

        let info      = sessionInfo
        let pairs     = effectivePairs
        let names     = snapInfo?.channelNames ?? [:]
        let shortNames = shortFilenames
        let pairedChs = Set(pairs.flatMap { [$0.left, $0.right] })

        state = .splitting(take: 0, totalTakes: 0, fraction: 0)

        let totalFrames = Double(info?.totalLength ?? 0)
        let ch = max(info?.numChannels ?? 1, 1)
        var cumulativeFrames: [Int: Double] = [:]
        if let info {
            var acc: Double = 0
            for i in 0 ..< info.takeSizes.count {
                cumulativeFrames[i + 1] = acc
                acc += Double(info.takeSizes[i]) / Double(ch)
            }
        }

        Task.detached { [weak self] in
            do {
                let result = try splitSession(
                    sessionDir: sessionDir,
                    outputDir: outputDir,
                    prefix: pfx,
                    stereoPairs: pairs,
                    channelNames: names,
                    useShortFilenames: shortNames,
                    progress: { take, total, framesInTake in
                        let before = cumulativeFrames[take] ?? 0
                        let fraction = totalFrames > 0
                            ? min((before + Double(framesInTake)) / totalFrames, 1.0)
                            : 0
                        Task { @MainActor in
                            self?.state = .splitting(take: take, totalTakes: total, fraction: fraction)
                        }
                    }
                )

                if let info, !info.markerSamples.isEmpty {
                    writeCueChunks(to: result.urls, markers: info.markerSamples)
                    exportMarkers(info, to: outputDir, prefix: pfx)
                    exportMIDIMarkers(info, to: outputDir, prefix: pfx)
                }

                let channelCount = info?.numChannels ?? 0
                let duration = info?.totalDuration ?? 0
                let extractedMono = result.keptMono
                let extractedStereo = result.keptStereo
                let silentStereo = pairs.count - extractedStereo
                let monoTrackCount = max((info?.numChannels ?? 0) - pairedChs.count, 0)
                let silentMono = monoTrackCount - extractedMono

                let markerList: [(time: Double, name: String)] = (info?.markerSamples ?? [])
                    .enumerated()
                    .map { i, s in (time: Double(s) / Double(info?.sampleRate ?? 48_000), name: "Marker \(i + 1)") }

                let owner = self
                await MainActor.run {
                    owner?.lastMarkers = markerList
                    owner?.state = .done(
                        channelCount: channelCount,
                        duration: duration,
                        extractedMono: extractedMono,
                        extractedStereo: extractedStereo,
                        silentMono: silentMono,
                        silentStereo: silentStereo,
                        outputDir: outputDir
                    )
                    // NSWorkspace.shared.open(outputDir)
                }
            } catch {
                let owner = self
                let msg = "\(error)"
                await MainActor.run {
                    owner?.state = .error(msg)
                }
            }
        }
    }

    func reset() {
        state = .idle
        sessionInfo = nil
        snapInfo = nil
        snapName = nil
        wavFiles = []
        outputBits = 32
        sessionName = ""
        customPairs = nil
        lastMarkers = []
    }
}
