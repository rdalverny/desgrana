// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI

struct UpdateAvailableView: View {
    let info: UpdateInfo
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Version \(info.version) available")
                .font(.headline)
            if !info.notes.isEmpty {
                ScrollView {
                    Text(info.notes)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Button("Later") { isPresented = false }
                Spacer()
                if let url = info.url {
                    Link("Download", destination: url)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
