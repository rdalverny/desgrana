// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

/// The idle drop target. Drop routing and folder picking stay in ContentView,
/// passed in as closures so they are shared with the ready view.
struct DropZoneView: View {
    @State private var isTargeted = false
    let onDrop: ([NSItemProvider]) -> Bool
    let onChoose: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                        )
                )
                .padding(16)

            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Drop a session folder here")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("with .wav, .bin, .snap/.scn files")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            onDrop(providers)
        }
        .contentShape(Rectangle())
        .onTapGesture { onChoose() }
        .onHover { hovered in
            if hovered { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help("Click to choose a session folder, or drop one here")
    }
}
