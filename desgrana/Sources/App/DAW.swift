// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import DesgranaCore
import Foundation
import SwiftUI

// MARK: - DAW detection

struct DAWInfo: Identifiable {
    let name: String
    let appURL: URL
    enum OpenMode { case reaper, openURLs, ardour }
    let mode: OpenMode
    var id: String { name }
}

func installedDAWs() -> [DAWInfo] {
    [installedLogicPro(), installedReaper(), installedArdour()]
        .compactMap { $0 }
}

// MARK: - Output file collection

func channelCount(of wav: URL) -> Int {
    (try? AVAudioFile(forReading: wav)).map { Int($0.processingFormat.channelCount) } ?? 1
}

func collectOutputFiles(in dir: URL) -> (wavs: [URL], midiURL: URL?) {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    let wavs = contents
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let midi = contents.first { $0.pathExtension.lowercased() == "mid" }
    return (wavs, midi)
}

// MARK: - Open in DAW

func openInDAW(
    _ daw: DAWInfo,
    dir: URL,
    duration: Double,
    sampleRate: Double,
    markers: [(time: Double, name: String)]
) {
    switch daw.mode {
    case .reaper:
        let (wavs, _) = collectOutputFiles(in: dir)
        guard !wavs.isEmpty,
              let rppURL = try? generateRPP(wavs: wavs.map { ($0, channelCount(of: $0)) },
                                            duration: duration, sampleRate: sampleRate,
                                            markers: markers, outputDir: dir)
        else { return }
        NSWorkspace.shared.open(rppURL)

    case .ardour:
        let (wavs, _) = collectOutputFiles(in: dir)
        guard !wavs.isEmpty,
              let ardourURL = try? generateArdourSession(wavs: wavs.map { ($0, channelCount(of: $0)) },
                                                        duration: duration, sampleRate: sampleRate,
                                                        markers: markers, outputDir: dir)
        else { return }
        NSWorkspace.shared.open(ardourURL)

    case .openURLs:
        let (wavs, midiURL) = collectOutputFiles(in: dir)
        var urls = wavs
        if let mid = midiURL { urls.append(mid) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: daw.appURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }
}

// MARK: - SwiftUI button row

struct DAWButtonsView: View {
    let dir: URL
    let duration: Double
    let sampleRate: Double
    let markers: [(time: Double, name: String)]

    @State private var daws: [DAWInfo] = []

    var body: some View {
        VStack(spacing: 4) {
            if !daws.isEmpty {
                Text("Open in DAW")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(daws) { daw in
                        Button(daw.name) {
                            openInDAW(daw, dir: dir, duration: duration, sampleRate: sampleRate,
                                      markers: markers)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }
        }
        .onAppear { daws = installedDAWs() }
    }
}
