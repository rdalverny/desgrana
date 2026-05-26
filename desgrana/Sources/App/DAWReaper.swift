// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

func installedReaper() -> DAWInfo? {
    let url = URL(fileURLWithPath: "/Applications/REAPER.app")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return DAWInfo(name: "Reaper", appURL: url, mode: .reaper)
}
