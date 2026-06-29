// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            VStack(spacing: 4) {
                Text("Desgrana").font(.title2.bold())
                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                Text("\(BuildInfo.gitDescribe) · \(BuildInfo.buildDate.prefix(10))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Text("From session to mix.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Link("github.com/rdalverny/desgrana",
                 destination: URL(string: Constants.URLs.github)!)
                .font(.callout)

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 400)
    }
}
