// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

extension Notification.Name {
    static let checkForUpdatesNow = Notification.Name("DesgranaCheckForUpdatesNow")
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Set when the OS opens the app with a file/folder (drag-to-icon, Open With…).
    @Published var pendingURL: URL?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURL = urls.first
    }
}

@main
struct DesgranaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var vm = SplitViewModel()
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate)
                .environmentObject(vm)
                .sheet(isPresented: $showAbout) { AboutView() }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Desgrana") { showAbout = true }
                Divider()
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForUpdatesNow, object: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(vm)
        }
    }
}
