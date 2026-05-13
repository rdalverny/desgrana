// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

func installedReaper() -> DAWInfo? {
    let url = URL(fileURLWithPath: "/Applications/REAPER.app")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return DAWInfo(name: "Reaper", appURL: url, mode: .reaper)
}

// Note: verify MARKER line syntax against a real .rpp saved by Reaper before shipping —
// the structure below matches Reaper 6+ community docs but minor version differences exist.

func generateRPP(
    wavs: [URL],
    duration: Double,
    sampleRate: Double,
    markers: [(time: Double, name: String)],
    outputDir: URL
) throws -> URL {
    let timestamp = Int(Date().timeIntervalSince1970)

    var lines: [String] = [
        "<REAPER_PROJECT 0.1 \"6.0\" \(timestamp)",
        "  SAMPLERATE \(Int(sampleRate)) 0 0",
        "  TEMPO 120 4 4"
    ]

    func guid() -> String { "{\(UUID().uuidString)}" }

    for wav in wavs {
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
            "        FILE \"\(wav.path)\"",
            "      >",
            "    >",
            "  >"
        ]
    }

    for (i, marker) in markers.enumerated() {
        lines.append(String(format:
            "  MARKER %d %.6f \"%@\" 0 0 1",
            i + 1, marker.time, marker.name))
    }

    lines.append(">")
    let content = lines.joined(separator: "\n") + "\n"
    let rppURL = outputDir.appendingPathComponent(outputDir.lastPathComponent + ".rpp")
    try content.write(to: rppURL, atomically: true, encoding: .utf8)
    return rppURL
}
