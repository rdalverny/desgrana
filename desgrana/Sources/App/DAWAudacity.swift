// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import AppKit
import Foundation

func installedAudacity() -> DAWInfo? {
    let url = URL(fileURLWithPath: "/Applications/Audacity.app")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return DAWInfo(name: "Audacity", appURL: url, mode: .audacity)
}

/// Opens a LOF session in Audacity.
///
/// Audacity tends to crash when handed a file to import while it is still
/// cold-starting. To avoid that, if Audacity is not already running we launch it
/// first and only open the LOF once the app is up; if it is already running we
/// open the LOF directly.
func openLOFInAudacity(_ lofURL: URL, appURL: URL) {
    let isRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
    }

    func openFile() {
        NSWorkspace.shared.open(
            [lofURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    if isRunning {
        openFile()
        return
    }

    // Cold start: launch the app, then open the LOF once it has finished launching.
    NSWorkspace.shared.openApplication(
        at: appURL,
        configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
        guard error == nil else { return }
        // Give Audacity a moment to finish initializing before importing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            openFile()
        }
    }
}
