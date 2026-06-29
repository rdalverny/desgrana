// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

/// The splitting / done / error states, shown in place of the drop zone.
struct TransientView: View {
    @EnvironmentObject private var vm: SplitViewModel

    var body: some View {
        ZStack {
            switch vm.state {
            case .splitting(let take, let total, let fraction):
                VStack(spacing: 12) {
                    ProgressView(value: fraction > 0 ? fraction : nil)
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    if total > 0 {
                        Text("Take \(take)/\(total) — \(Int(fraction * 100)) %")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Extracting \(vm.sessionName)…")
                            .foregroundStyle(.secondary)
                    }
                }

            case .done(let channels, let duration, let extractedMono, let extractedStereo, let silentMono, let silentStereo, let dir):
                VStack(spacing: 12) {
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Extraction complete")
                        .font(.title3)
                    VStack(spacing: 3) {
                        Text("\(channels) ch · \(formatTime(duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        let tracksLabel: (Int, Int) -> String = { stereo, mono in
                            var parts: [String] = []
                            if stereo > 0 { parts.append("\(stereo) stereo") }
                            if mono > 0 { parts.append("\(mono) mono") }
                            return parts.isEmpty ? "0" : parts.joined(separator: ", ")
                        }
                        let silent = silentMono + silentStereo
                        let silentSuffix = silent > 0
                            ? " · \(tracksLabel(silentStereo, silentMono)) silent ignored" : ""
                        Text("\(tracksLabel(extractedStereo, extractedMono)) extracted\(silentSuffix)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("New session") { vm.reset() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        Button("Reveal in Finder") { NSWorkspace.shared.open(dir) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                    DAWButtonsView(dir: dir,
                                  duration: duration,
                                  sampleRate: Double(vm.sessionInfo?.sampleRate ?? 48_000),
                                  markers: vm.lastMarkers)
                        .padding(.top, 4)
                    Spacer(minLength: 8)
                }

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Start over") { vm.reset() }
                        .font(.caption)
                }

            default:
                EmptyView()
            }
        }
    }
}
