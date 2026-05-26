// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
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
