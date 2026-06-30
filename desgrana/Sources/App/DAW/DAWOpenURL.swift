// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// DAWs that accept audio and MIDI files opened directly via NSWorkspace.
// Add any new DAW here if it supports this approach without needing a session file.

func installedLogicPro() -> DAWInfo? {
    let url = URL(fileURLWithPath: "/Applications/Logic Pro.app")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return DAWInfo(name: "Logic Pro", appURL: url, mode: .openURLs)
}
