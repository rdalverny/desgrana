// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

struct SettingsView: View {
    @EnvironmentObject private var vm: SplitViewModel
    @AppStorage(updateCheckEnabledKey) private var updateEnabled: Bool = true
    @AppStorage(updateCheckIntervalKey) private var updateIntervalDays: Int = 30

    var body: some View {
        Form {
            Section {
                Toggle("Use short filenames", isOn: $vm.shortFilenames)
                Text(vm.shortFilenames
                    ? "Channel name only: KICK.wav, ch01.wav"
                    : "Session prefix: MyShow_KICK.wav, MyShow_ch01.wav")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if let dir = vm.customOutputDir {
                    LabeledContent("Output folder") {
                        Text(dir.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("Default output folder: ~/Desktop/<session name>")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK { vm.customOutputDir = panel.url }
                    }
                    if vm.customOutputDir != nil {
                        Button("Reset to default") { vm.customOutputDir = nil }
                    }
                }
            }

            Section {
                Toggle("Check for updates automatically", isOn: $updateEnabled)
                if updateEnabled {
                    Picker("Every", selection: $updateIntervalDays) {
                        Text("Week").tag(7)
                        Text("Month").tag(30)
                        Text("6 months").tag(180)
                    }
                    .pickerStyle(.menu)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        vm.shortFilenames = true
                        vm.customOutputDir = nil
                        updateEnabled = true
                        updateIntervalDays = 30
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
