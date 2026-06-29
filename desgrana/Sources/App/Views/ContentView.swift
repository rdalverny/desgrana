// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

struct ContentView: View {
    @EnvironmentObject private var vm: SplitViewModel
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var sessionNameHovered = false
    @State private var destHovered = false
    @State private var updateInfo: UpdateInfo?
    @State private var showUpdateSheet = false
    @State private var showUpToDateAlert = false

    var body: some View {
        VStack(spacing: 0) {
            switch vm.state {
            case .idle:
                DropZoneView(onDrop: handleDrop, onChoose: chooseSession)
                    .frame(width: 480, height: 220)
            case .ready(let url):
                readyView(sessionDir: url)
            case .splitting, .error:
                TransientView()
                    .frame(width: 480, height: 220)
            case .done:
                TransientView()
                    .frame(width: 480)
            }

        }
        .frame(width: 480)
        .fixedSize()
        .onAppear {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            NSApp.windows.first?.title = "Desgrana"
            UserDefaults.standard.set(600, forKey: "NSInitialToolTipDelay")
            handlePendingURL()
            Task.detached(priority: .background) {
                if let info = await UpdateCheck.checkIfDue(current: v) {
                    await MainActor.run {
                        self.updateInfo = info
                        self.showUpdateSheet = true
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkForUpdatesNow)) { _ in
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            Task.detached(priority: .background) {
                if let info = await UpdateCheck.checkNow(current: v) {
                    await MainActor.run {
                        self.updateInfo = info
                        self.showUpdateSheet = true
                    }
                } else {
                    await MainActor.run { self.showUpToDateAlert = true }
                }
            }
        }
        .onChange(of: appDelegate.pendingURL) { _ in handlePendingURL() }
        .sheet(isPresented: $showUpdateSheet) {
            UpdateAvailableView(info: updateInfo!, isPresented: $showUpdateSheet)
        }
        .alert("Desgrana is up to date", isPresented: $showUpToDateAlert) {
            Button("OK") {}
        }
    }

    // MARK: - Ready view

    func readyView(sessionDir: URL) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                TextField("Session name", text: Binding(
                    get: { vm.sessionName }, set: { vm.sessionName = $0 }))
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .onChange(of: vm.sessionName) { v in
                        if v.count > 300 { vm.sessionName = String(v.prefix(300)) }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(sessionNameHovered ? 0.22 : 0), lineWidth: 1)
                    )
                    .onHover { sessionNameHovered = $0 }
                    .padding(.horizontal, -5)
                Spacer()
                Button("Clear session") { vm.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Make sure your tracks are grouped as expected below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 0)
                TrackListView()
                    .padding(.horizontal, -4)
                statusLine(sessionDir: sessionDir)
                    .padding(.bottom, 6)
                destinationLine(sessionDir: sessionDir)

                if vm.snapInfo == nil {
                    HStack(spacing: 6) {
                        Text("No snapshot \u{2014} channel names will be numbered.")
                        Button("Add\u{2026}") { browseSnap() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .center) {
                    Button("Choose a different folder…") {
                        chooseOutputDir(sessionDir: sessionDir)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button("Extract") { vm.split(sessionDir: sessionDir) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Status + destination

    func statusLine(sessionDir: URL) -> some View {
        HStack(spacing: 6) {
            if let info = vm.sessionInfo {
                Text(formatDuration(info.totalDuration)).monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                let missing = info.numTakes - vm.wavFiles.count
                if missing > 0 {
                    Text("\(vm.wavFiles.count)/\(info.numTakes) files")
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(missing) missing").foregroundStyle(.orange)
                } else {
                    Text("\(info.numTakes) file\(info.numTakes == 1 ? "" : "s")")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .onTapGesture { NSWorkspace.shared.open(sessionDir) }
        .help("Show session folder in Finder")
    }

    func destinationLine(sessionDir: URL) -> some View {
        let outputURL = vm.customOutputDir ?? vm.defaultOutputDir(for: sessionDir)
        let outputExists = FileManager.default.fileExists(atPath: outputURL.path)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Output folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .opacity(destHovered ? 0.6 : 0)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(String(displayPath(outputURL).prefix(300)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if vm.customOutputDir != nil {
                    Button {
                        vm.customOutputDir = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            if outputExists {
                Label("This folder already exists — files may be overwritten.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let lowDisk = lowDiskWarning(sessionDir: sessionDir, outputURL: outputURL) {
                Label(lowDisk, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            destHovered
                ? RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04))
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture { chooseOutputDir(sessionDir: sessionDir) }
        .onHover { hovered in
            destHovered = hovered
            if hovered { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help("Click to change the output folder")
        .padding(.horizontal, -4)
    }

    /// Returns a warning string when the destination volume has less than 2x the
    /// expected extracted size free, else nil. Expected size is approximated by the
    /// total size of the source WAV takes (extraction reorganizes the same samples).
    func lowDiskWarning(sessionDir: URL, outputURL: URL) -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let expected = contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .reduce(Int64(0)) { acc, url in
                acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        guard expected > 0 else { return nil }

        // Available capacity on the nearest existing ancestor (the dir may not exist yet).
        var probe = outputURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        let avail = (try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let needed = expected * 2
        guard avail < needed else { return nil }

        let fmt = ByteCountFormatter()
        return "Low disk space: \(fmt.string(fromByteCount: avail)) free, "
            + "about \(fmt.string(fromByteCount: needed)) recommended."
    }

    func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        if h > 0 {
            return String(format: "%dh %dmin %06.3f", h, m, s)
        } else if m > 0 {
            return String(format: "%dmin %06.3f", m, s)
        } else {
            return String(format: "%.3f s", s)
        }
    }

    // MARK: - Drop & file handling

    func handlePendingURL() {
        guard let url = appDelegate.pendingURL else { return }
        appDelegate.pendingURL = nil
        let ext = url.pathExtension.lowercased()
        if ["snap", "scn"].contains(ext) {
            vm.loadSnap(url: url)
        } else if url.hasDirectoryPath || isDirectory(url) || ext == "wav" {
            vm.loadSession(url: url)
        }
    }

    func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    func chooseOutputDir(sessionDir: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = "Choose output destination"
        panel.directoryURL = vm.customOutputDir ?? vm.defaultOutputDir(for: sessionDir)
        if panel.runModal() == .OK, let url = panel.url {
            vm.customOutputDir = url
        }
    }

    func chooseSession() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Choose a session folder"
        if panel.runModal() == .OK, let url = panel.url {
            vm.loadSession(url: url)
        }
    }

    func browseSnap() {
        let panel = NSOpenPanel()
        panel.title = "Select Console Snapshot"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Select a .snap (Wing) or .scn (X32) snapshot file"
        if panel.runModal() == .OK, let url = panel.url,
           ["snap", "scn"].contains(url.pathExtension.lowercased()) {
            vm.loadSnap(url: url)
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else { return }
            Task { @MainActor in
                let ext = url.pathExtension.lowercased()
                if ["snap", "scn"].contains(ext) {
                    vm.loadSnap(url: url)
                } else if url.hasDirectoryPath || isDirectory(url) || ext == "wav" {
                    vm.loadSession(url: url)
                }
            }
        }
        return true
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
