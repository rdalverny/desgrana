// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import AVFoundation
import Foundation

func installedArdour() -> DAWInfo? {
    let appsURL = URL(fileURLWithPath: "/Applications")
    let apps = (try? FileManager.default.contentsOfDirectory(
        at: appsURL, includingPropertiesForKeys: nil
    )) ?? []
    guard let app = apps.first(where: {
        $0.deletingPathExtension().lastPathComponent.hasPrefix("Ardour")
        && $0.pathExtension == "app"
    }) else { return nil }
    return DAWInfo(name: "Ardour", appURL: app, mode: .ardour)
}

// Generates a minimal Ardour session file (.ardour) with one mono track per WAV.
// XML format verified against session version 3002 (Ardour 6/7) via the
// fcpXmlToArdour project templates (github.com/s-leroux/fcpXmlToArdour) and
// a sample session file. Test with actual Ardour before shipping.
// Marker flag "IsMark" is consistent with Ardour source conventions but should
// be confirmed against a real session with markers.
func generateArdourSession(
    wavs: [URL],
    duration: Double,
    sampleRate: Double,
    markers: [(time: Double, name: String)],
    outputDir: URL
) throws -> URL {
    struct Track {
        let wav: URL
        let name: String
        let frames: Int64
        let channels: UInt32
        let sourceID: Int
        let regionID: Int
        let playlistID: Int
        let routeID: Int
        let diskstreamID: Int
    }

    var idCounter = 1
    func nextID() -> Int { defer { idCounter += 1 }; return idCounter }

    let sessionFrames = Int64(duration * sampleRate)

    var tracks: [Track] = []
    for wav in wavs {
        let name = wav.deletingPathExtension().lastPathComponent
        // Channel count genuinely varies (1 for mono, 2 for stereo tracks).
        let channels: UInt32 = (try? AVAudioFile(forReading: wav))
            .map { $0.processingFormat.channelCount } ?? 1
        tracks.append(Track(
            wav: wav, name: name, frames: sessionFrames, channels: channels,
            sourceID: nextID(), regionID: nextID(),
            playlistID: nextID(), routeID: nextID(), diskstreamID: nextID()
        ))
    }

    let sessionEnd   = tracks.map(\.frames).max() ?? 0
    let sessionLocID = nextID()
    let markerIDs    = markers.map { _ in nextID() }
    let sessionName  = outputDir.lastPathComponent

    func x(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func tag(_ name: String, _ attrs: [(String, String)], selfClosing: Bool = true) -> String {
        let a = attrs.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
        return selfClosing ? "<\(name) \(a)/>" : "<\(name) \(a)>"
    }

    var lines: [String] = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        tag("Session", [
            ("version",       "3002"),
            ("name",          x(sessionName)),
            ("sample-rate",   "\(Int(sampleRate))"),
            ("end-is-free",   "1"),
            ("id-counter",    "\(idCounter)"),
            ("name-counter",  "1"),
            ("event-counter", "0"),
            ("vca-counter",   "1")
        ], selfClosing: false) + ">",
        "  <Sources>"
    ]

    for t in tracks {
        lines.append("  " + tag("Source", [
            ("name",    x(t.wav.lastPathComponent)),
            ("type",    "audio"),
            ("flags",   ""),
            ("id",      "\(t.sourceID)"),
            ("channel", "0"),
            ("origin",  "./\(x(t.wav.lastPathComponent))"),
            ("gain",    "1")
        ]))
    }

    lines += ["  </Sources>", "  <Regions/>", "  <Playlists>"]

    for t in tracks {
        lines += [
            "  " + tag("Playlist", [
                ("id",              "\(t.playlistID)"),
                ("name",            "\(x(t.name)).1"),
                ("type",            "audio"),
                ("orig-track-id",   "\(t.routeID)"),
                ("shared-with-ids", ""),
                ("frozen",          "0"),
                ("combine-ops",     "0")
            ], selfClosing: false) + ">",
            "    " + tag("Region", [
                ("name",                  x(t.name)),
                ("muted",                 "0"),
                ("opaque",                "1"),
                ("locked",                "0"),
                ("video-locked",          "0"),
                ("automatic",             "0"),
                ("whole-file",            "1"),
                ("import",                "0"),
                ("external",              "1"),
                ("sync-marked",           "0"),
                ("left-of-split",         "0"),
                ("right-of-split",        "0"),
                ("hidden",                "0"),
                ("position-locked",       "0"),
                ("valid-transients",      "0"),
                ("start",                 "0"),
                ("length",                "\(t.frames)"),
                ("position",              "0"),
                ("beat",                  "0"),
                ("sync-position",         "0"),
                ("ancestral-start",       "0"),
                ("ancestral-length",      "\(t.frames)"),
                ("stretch",               "1"),
                ("shift",                 "1"),
                ("positional-lock-style", "AudioTime"),
                ("layering-index",        "0"),
                ("envelope-active",       "0"),
                ("default-fade-in",       "0"),
                ("default-fade-out",      "0"),
                ("fade-in-active",        "1"),
                ("fade-out-active",       "1"),
                ("scale-amplitude",       "1"),
                ("id",                    "\(t.regionID)"),
                ("type",                  "audio"),
                ("first-edit",            "nothing"),
                ("source-0",              "\(t.sourceID)"),
                ("master-source-0",       "\(t.sourceID)"),
                ("channels",              "\(t.channels)")
            ]),
            "  </Playlist>"
        ]
    }

    lines += ["  </Playlists>", "  <UnusedPlaylists/>", "  <Routes>"]

    for t in tracks {
        lines += [
            "  " + tag("Route", [
                ("id",                  "\(t.routeID)"),
                ("name",                x(t.name)),
                ("default-type",        "audio"),
                ("strict-io",           "1"),
                ("active",              "1"),
                ("denormal-protection", "0"),
                ("meter-point",         "MeterPostFader"),
                ("meter-type",          "MeterPeak"),
                ("saved-meter-point",   "MeterPostFader"),
                ("mode",                "Normal")
            ], selfClosing: false) + ">",
            "    " + tag("Diskstream", [
                ("flags",              "Recordable"),
                ("playlist",           "\(x(t.name)).1"),
                ("name",               x(t.name)),
                ("id",                 "\(t.diskstreamID)"),
                ("speed",              "1"),
                ("capture-alignment",  "Automatic"),
                ("record-safe",        "0"),
                ("channels",           "\(t.channels)")
            ]),
            "  </Route>"
        ]
    }

    lines += ["  </Routes>", "  <Locations>"]
    lines.append("  " + tag("Location", [
        ("id",                  "\(sessionLocID)"),
        ("name",                "session"),
        ("start",               "0"),
        ("end",                 "\(sessionEnd)"),
        ("flags",               "IsSessionRange"),
        ("locked",              "0"),
        ("position-lock-style", "AudioTime")
    ]))
    for (i, marker) in markers.enumerated() {
        let sample = Int64(marker.time * sampleRate)
        lines.append("  " + tag("Location", [
            ("id",                  "\(markerIDs[i])"),
            ("name",                x(marker.name)),
            ("start",               "\(sample)"),
            ("end",                 "\(sample)"),
            ("flags",               "IsMark"),
            ("locked",              "0"),
            ("position-lock-style", "AudioTime")
        ]))
    }
    lines += ["  </Locations>", "</Session>"]

    let content = lines.joined(separator: "\n") + "\n"
    let ardourURL = outputDir.appendingPathComponent(sessionName + ".ardour")
    try content.write(to: ardourURL, atomically: true, encoding: .utf8)
    return ardourURL
}
