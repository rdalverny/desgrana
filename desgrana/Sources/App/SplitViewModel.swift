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
    @Published private(set) var lastMarkers: [(time: Double, name: String)] = []
    /// Resolved takes for the current input (hex session, single file, or single WAV in a dir).
    @Published var resolvedTakes: [URL] = []
    /// Channel count inferred from the WAV header when there is no SE_LOG.bin (other recorders).
    @Published var inferredChannels: Int?
    /// Track names from the WAV itself when there is no snap (placeholder until iXML parsing lands).
    @Published var fallbackChannelNames: [Int: String] = [:]
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

    // Pairs derived from the snap.
    // USB pairs are taken from the snap config as-is (explicit hardware routing).
    // LCL pairs are detected from channel names (L/R suffixes); no name means mono.
    // clink is not used — it reflects live console behaviour, not recording intent.
    var snapDerivedPairs: [StereoPair] {
        let numCh = sessionInfo?.numChannels ?? inferredChannels ?? 0
        guard numCh > 0 else { return [] }

        let usbPairs = filterStereoPairs(snapInfo?.usbStereoPairs ?? [], channelCount: numCh)
        let usbTracks = Set(usbPairs.flatMap { [$0.left, $0.right] })
        let lclPairs = detectStereoPairsFromNames(snapInfo?.channelNames ?? [:], channelCount: numCh)
            .filter { !usbTracks.contains($0.left) }

        return (usbPairs + lclPairs).sorted { $0.left < $1.left }
    }

    // Pairs used for splitting: manual user override takes precedence, then snap-derived.
    var effectivePairs: [StereoPair] {
        userOverridePairs ?? snapDerivedPairs
    }

    // Channel names for splitting: snap names, with _L/_R suffixes added to both tracks
    // of any USB stereo pair that has been manually unlinked.
    var effectiveChannelNames: [Int: String] {
        applyUsbUnpairRename(
            names: snapInfo?.channelNames ?? fallbackChannelNames,
            usbPairs: snapInfo?.usbStereoPairs ?? [],
            activePairs: effectivePairs
        )
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
        // Resolve whatever was dropped: a session folder (hex takes), a single WAV file,
        // or a folder with one WAV. Several non-hex WAVs in a folder is refused.
        let resolved = resolveSessionTakes(at: url)
        if case .ambiguous = resolved {
            reset()
            state = .error("This folder contains several WAV files. Drop a single file, or a session folder.")
            return
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isFileInput = !isDir.boolValue
        let dir = isFileInput ? url.deletingLastPathComponent() : url

        let selog = seLogCandidates
            .lazy
            .map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        sessionInfo = selog.flatMap { try? parseSELog(at: $0) }

        if let snapURL = findConsoleSnapshot(in: dir) {
            snapInfo = try? parseSnapOrScene(at: snapURL)
            snapName = snapURL.lastPathComponent
        } else {
            snapInfo = nil
            snapName = nil
        }
        userOverridePairs = nil

        if case .ok(let t) = resolved { resolvedTakes = t } else { resolvedTakes = [] }
        wavFiles = resolvedTakes

        // No SE_LOG: read the channel count from the first WAV header so the track list shows up.
        inferredChannels = sessionInfo == nil
            ? resolvedTakes.first.flatMap { probeWavHeader(at: $0)?.channels }
            : nil

        // No snap: try track names embedded in the WAV (placeholder until iXML parsing lands).
        fallbackChannelNames = snapInfo == nil
            ? (resolvedTakes.first.map { parseIXMLTrackNames(at: $0) } ?? [:])
            : [:]

        sessionName = isFileInput
            ? url.deletingPathExtension().lastPathComponent
            : bestSessionName(sessionDir: dir)

        if resolvedTakes.isEmpty {
            state = .error("No WAV takes found in this directory.")
        } else {
            state = .ready(dir)
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
        let names     = effectiveChannelNames
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
        let capturedTakes = resolvedTakes
        let fallbackCh = inferredChannels
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

                writeIXMLChunks(to: result.outputs)
                writeBextChunks(to: result.outputs, source: capturedTakes.first,
                                sampleRate: info?.sampleRate ?? Int(result.sampleRate))

                if let info, !info.markerSamples.isEmpty {
                    writeCueChunks(to: result.outputs.map(\.url), markers: info.markerSamples)
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
        resolvedTakes = []
        inferredChannels = nil
        fallbackChannelNames = [:]
    }
}
