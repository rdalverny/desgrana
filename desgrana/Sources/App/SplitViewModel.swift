// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Combine
import SwiftUI
import DesgranaCore
import DesgranaCoreAudioToolbox

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
    @Published var userOverridePairs: [StereoPair]?
    @Published var customOutputDir: URL?
    @Published var shortFilenames: Bool = true
    @Published var useAutoStereo: Bool = true
    @Published private(set) var lastMarkers: [(time: Double, name: String)] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        shortFilenames = UserDefaults.standard.object(forKey: "shortFilenames") as? Bool ?? true
        useAutoStereo = UserDefaults.standard.object(forKey: "useAutoStereo") as? Bool ?? true
        if let path = UserDefaults.standard.string(forKey: "outputDirPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { customOutputDir = url }
        }
        $shortFilenames
            .sink { UserDefaults.standard.set($0, forKey: "shortFilenames") }
            .store(in: &cancellables)
        $useAutoStereo
            .sink { UserDefaults.standard.set($0, forKey: "useAutoStereo") }
            .store(in: &cancellables)
        $customOutputDir
            .sink { UserDefaults.standard.set($0?.path, forKey: "outputDirPath") }
            .store(in: &cancellables)
    }

    // True when snap has all session channels linked — Wing factory default state.
    // In that case clink carries no user intent and should be ignored.
    var snapIsFactoryDefault: Bool {
        guard let numCh = sessionInfo?.numChannels, numCh > 0 else { return false }
        return (snapInfo?.stereoPairs ?? []).count == numCh / 2
    }

    // Pairs derived from the snap: name-based detection when clink is meaningless,
    // otherwise the user's actual configured pairs (filtered to session channel count).
    var snapDerivedPairs: [StereoPair] {
        let numCh = sessionInfo?.numChannels ?? 0
        guard numCh > 0 else { return [] }
        if useAutoStereo {
            return detectStereoPairsFromNames(snapInfo?.channelNames ?? [:], channelCount: numCh)
        }
        return filterStereoPairs(snapInfo?.stereoPairs ?? [], channelCount: numCh)
    }

    // Pairs used for splitting: manual user override takes precedence, then snap-derived.
    var effectivePairs: [StereoPair] {
        userOverridePairs ?? snapDerivedPairs
    }

    var isCustomized: Bool { userOverridePairs != nil }

    func unlinkPair(left: Int) {
        var p = effectivePairs
        p.removeAll { $0.left == left }
        userOverridePairs = p
    }

    func linkChannels(_ left: Int, _ right: Int) {
        var p = effectivePairs
        p.removeAll { $0.left == left || $0.right == left || $0.left == right || $0.right == right }
        p.append(StereoPair(left: left, right: right))
        userOverridePairs = p.sorted { $0.left < $1.left }
    }

    func resetPairs() { userOverridePairs = nil }

    func bestSessionName(sessionDir: URL) -> String {
        if let scene = snapInfo?.sceneName, !scene.isEmpty { return scene }
        return nonameFallback()
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

        if let snapURL = findConsoleSnapshot(in: url) {
            snapInfo = try? parseSnapOrScene(at: snapURL)
            snapName = snapURL.lastPathComponent
        } else {
            snapInfo = nil
            snapName = nil
        }
        userOverridePairs = nil

        wavFiles = findWavTakes(in: url)
        sessionName = bestSessionName(sessionDir: url)
        if wavFiles.isEmpty {
            state = .error("No WAV takes found in this directory.")
        } else {
            state = .ready(url)
        }
    }

    func loadSnap(url: URL) {
        if let info = try? parseSnapOrScene(at: url) {
            snapInfo = info
            snapName = url.lastPathComponent
            userOverridePairs = nil
            if let scene = info.sceneName, !scene.isEmpty {
                sessionName = scene
            }
        }
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
        // framesBeforeTake[N] = total frames already processed before take N starts.
        // takeSizes are in interleaved samples (frames × channels), so divide by ch to get frames.
        // Keyed by 1-based take number to match the progress callback.
        var framesBeforeTake: [Int: Double] = [:]
        if let info {
            var acc: Double = 0
            for i in 0 ..< info.takeSizes.count {
                framesBeforeTake[i + 1] = acc
                acc += Double(info.takeSizes[i]) / Double(ch)
            }
        }

        let capturedFrames = framesBeforeTake
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
                        let before = capturedFrames[take] ?? 0
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

    private func nonameFallback() -> String {
        let c = Calendar.current
        let n = Date()
        return String(format: "NONAME_%02d%02d%02d%02d",
            c.component(.year,  from: n) % 100,
            c.component(.month, from: n),
            c.component(.day,   from: n),
            c.component(.hour,  from: n))
    }

    func reset() {
        state = .idle
        sessionInfo = nil
        snapInfo = nil
        snapName = nil
        wavFiles = []
        sessionName = ""
        userOverridePairs = nil
        lastMarkers = []
    }
}
