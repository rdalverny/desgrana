// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import Foundation
import SwiftUI

// MARK: - DAW detection

struct DAWInfo: Identifiable {
    let name: String
    let appURL: URL
    enum OpenMode { case reaper, openURLs }
    let mode: OpenMode
    var id: String { name }
}

func installedDAWs() -> [DAWInfo] {
    var result: [DAWInfo] = []
    let fm = FileManager.default

    let logicURL = URL(fileURLWithPath: "/Applications/Logic Pro.app")
    if fm.fileExists(atPath: logicURL.path) {
        result.append(DAWInfo(name: "Logic Pro", appURL: logicURL, mode: .openURLs))
    }

    let reaperURL = URL(fileURLWithPath: "/Applications/REAPER.app")
    if fm.fileExists(atPath: reaperURL.path) {
        result.append(DAWInfo(name: "Reaper", appURL: reaperURL, mode: .reaper))
    }

    // Not sure how to handle a Live session yet
    // if let apps = try? fm.contentsOfDirectory(
    //     at: URL(fileURLWithPath: "/Applications"),
    //     includingPropertiesForKeys: nil
    // ), let liveApp = apps.first(where: {
    //     let n = $0.lastPathComponent
    //     return n.hasPrefix("Ableton Live") && n.hasSuffix(".app")
    // }) {
    //     result.append(DAWInfo(name: "Ableton Live", appURL: liveApp, mode: .openURLs))
    // }

    return result
}

// MARK: - WAV header

private struct WAVHeader {
    let sampleRate: UInt32
    let numChannels: UInt16
    let bitsPerSample: UInt16
    let dataSize: UInt32
    var duration: Double {
        guard dataSize != 0xFFFF_FFFF, sampleRate > 0,
              numChannels > 0, bitsPerSample > 0 else { return 0 }
        return Double(dataSize) / Double(sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8)
    }
}

private func readWAVHeader(at url: URL) -> WAVHeader? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    let bytes = (try? fh.read(upToCount: 512)) ?? Data()
    try? fh.close()

    guard bytes.count >= 12,
          bytes[0..<4].elementsEqual("RIFF".utf8),
          bytes[8..<12].elementsEqual("WAVE".utf8) else { return nil }

    func u32(at i: Int) -> UInt32 {
        guard i + 4 <= bytes.count else { return 0 }
        return bytes.withUnsafeBytes { $0.load(fromByteOffset: i, as: UInt32.self).littleEndian }
    }
    func u16(at i: Int) -> UInt16 {
        guard i + 2 <= bytes.count else { return 0 }
        return bytes.withUnsafeBytes { $0.load(fromByteOffset: i, as: UInt16.self).littleEndian }
    }

    var pos = 12
    var sampleRate: UInt32 = 0
    var numChannels: UInt16 = 0
    var bitsPerSample: UInt16 = 0
    var dataSize: UInt32 = 0
    var foundFmt = false

    while pos + 8 <= bytes.count {
        let chunkSize = u32(at: pos + 4)
        let isData    = bytes[pos..<pos+4].elementsEqual("data".utf8)
        let isFmt     = bytes[pos..<pos+4].elementsEqual("fmt ".utf8)
        pos += 8

        if isFmt, !foundFmt {
            guard pos + 16 <= bytes.count else { break }
            numChannels   = u16(at: pos + 2)
            sampleRate    = u32(at: pos + 4)
            bitsPerSample = u16(at: pos + 14)
            foundFmt = true
        } else if isData {
            dataSize = chunkSize
            break
        }

        let advance = Int(chunkSize) + Int(chunkSize & 1)
        guard advance > 0 else { break }
        pos += advance
    }

    guard foundFmt else { return nil }
    return WAVHeader(sampleRate: sampleRate, numChannels: numChannels,
                     bitsPerSample: bitsPerSample, dataSize: dataSize)
}

// MARK: - Output file collection

private func collectOutputFiles(in dir: URL) -> (wavs: [URL], midiURL: URL?) {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    let wavs = contents
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let midi = contents.first { $0.pathExtension.lowercased() == "mid" }
    return (wavs, midi)
}

// MARK: - Reaper RPP generation

// Note: verify MARKER line syntax against a real .rpp saved by Reaper before shipping —
// the structure below matches Reaper 6+ community docs but minor version differences exist.
private func wavDuration(at url: URL) -> Double {
    guard let f = try? AVAudioFile(forReading: url) else { return 0 }
    let sr = f.processingFormat.sampleRate
    return sr > 0 ? Double(f.length) / sr : 0
}

private func generateRPP(
    wavs: [URL],
    markers: [(time: Double, name: String)],
    outputDir: URL
) throws -> URL {
    let sampleRate: Double = (try? AVAudioFile(forReading: wavs[0]))
        .map { $0.processingFormat.sampleRate } ?? 48_000
    let timestamp  = Int(Date().timeIntervalSince1970)

    var lines: [String] = [
        "<REAPER_PROJECT 0.1 \"6.0\" \(timestamp)",
        "  SAMPLERATE \(Int(sampleRate)) 0 0"
    ]

    func guid() -> String { "{\(UUID().uuidString)}" }

    for wav in wavs {
        let duration  = wavDuration(at: wav)
        let relPath   = "./\(wav.lastPathComponent)"
        let trackName = wav.deletingPathExtension().lastPathComponent
        lines += [
            "  <TRACK \(guid())",
            "    NAME \"\(trackName)\"",
            "    <ITEM",
            "      POSITION 0",
            String(format: "      LENGTH %.6f", duration),
            "      LOOP 0",
            "      GUID \(guid())",
            "      <SOURCE WAVE",
            "        FILE \"\(relPath)\"",
            "      >",
            "    >",
            "  >"
        ]
    }

    for (i, marker) in markers.enumerated() {
        lines.append(String(format:
            "  MARKER %d %.6f \"%@\" 0 0 1 B {00000000-0000-0000-0000-000000000000} 0",
            i + 1, marker.time, marker.name))
    }

    lines.append(">")
    let content = lines.joined(separator: "\n") + "\n"
    let rppURL = outputDir.appendingPathComponent(outputDir.lastPathComponent + ".rpp")
    try content.write(to: rppURL, atomically: true, encoding: .utf8)
    return rppURL
}

// MARK: - Open in DAW

func openInDAW(_ daw: DAWInfo, dir: URL, markers: [(time: Double, name: String)]) {
    switch daw.mode {
    case .reaper:
        let (wavs, _) = collectOutputFiles(in: dir)
        guard !wavs.isEmpty,
              let rppURL = try? generateRPP(wavs: wavs, markers: markers, outputDir: dir)
        else { return }
        NSWorkspace.shared.open(rppURL)

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
                            openInDAW(daw, dir: dir, markers: markers)
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
