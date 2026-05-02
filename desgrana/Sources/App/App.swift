// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore
import DesgranaCoreMac

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
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate)
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
    }
}

// MARK: - About

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
            }

            Text("Extract channels from your Behringer Wing / X-Live / W-Live\nmultitrack recordings into mono or stereo WAV files.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            Divider()

            Link("github.com/rdalverny/desgrana",
                 destination: URL(string: "https://github.com/rdalverny/desgrana")!)
                .font(.callout)

            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 400)
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = SplitViewModel()
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var isTargeted = false
    @State private var updateInfo: UpdateInfo?
    @State private var showUpdateSheet = false
    @State private var showUpToDateAlert = false

    var body: some View {
        VStack(spacing: 0) {
            switch vm.state {
            case .idle:
                dropZone
                    .frame(width: 480, height: 220)
            case .ready(let url):
                readyView(sessionDir: url)
            case .splitting, .error:
                transientView
                    .frame(width: 480, height: 220)
            case .done:
                transientView
                    .frame(width: 480)
            }

        }
        .frame(width: 480)
        .fixedSize()
        .onAppear {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            NSApp.windows.first?.title = "Desgrana \(v)"
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

    // MARK: - Drop zone (idle only)

    var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                )
                .padding(16)

            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a session folder here")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("with .wav, .bin, .snap files")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Transient view (splitting / done / error)

    var transientView: some View {
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
                        Text("Preparing…")
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
                            ? " · \(tracksLabel(silentStereo, silentMono)) silent" : ""
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
                    DAWButtonsView(dir: dir, markers: vm.lastMarkers)
                        .padding(.top, 4)
                    Spacer(minLength: 8)
                }

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40, weight: .light))
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

    // MARK: - Ready view

    func readyView(sessionDir: URL) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Session name", text: $vm.sessionName)
                        .font(.headline)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                    Text(sessionDir.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reset") { vm.reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            VStack(spacing: 10) {
                if let info = vm.sessionInfo {
                    inputSection(info: info)
                }

                snapSection(sessionDir: sessionDir)
                outputSummary(sessionDir: sessionDir)

                HStack {
                    Spacer()
                    Button("Extract") { vm.split(sessionDir: sessionDir) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Input section

    func inputSection(info: SessionInfo) -> some View {
        let foundNames = Set(vm.wavFiles.map {
            $0.deletingPathExtension().lastPathComponent.lowercased()
        })
        let ch = max(info.numChannels, 1)
        let sr = Double(info.sampleRate)
        let missing = info.numTakes - vm.wavFiles.count
        let showTakes = info.numTakes > 1 || missing > 0
        let filesLabel = missing > 0
            ? "\(vm.wavFiles.count)/\(info.numTakes)"
            : "\(info.numTakes) file\(info.numTakes == 1 ? "" : "s")"

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Labels row then values row
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                    GridRow {
                        Text("channels").foregroundStyle(.secondary)
                        Text("sampling").foregroundStyle(.secondary)
                        Text("bit depth").foregroundStyle(.secondary)
                        if info.markerSamples.count > 0 {
                            Text("markers").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("\(info.numChannels)").monospacedDigit().bold()
                        Text("\(info.sampleRate) Hz").monospacedDigit().bold()
                        Text("\(vm.outputBits)-bit").bold()
                        if info.markerSamples.count > 0 {
                            Text("\(info.markerSamples.count)").monospacedDigit().bold()
                        }
                    }
                }
                .font(.caption)

                // Duration + per-take breakdown, columns aligned
                Grid(horizontalSpacing: 16, verticalSpacing: 2) {
                    GridRow {
                        Text("duration")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(formatDuration(info.totalDuration))
                            .monospacedDigit()
                            .bold()
                            .gridColumnAlignment(.trailing)
                        Text(filesLabel)
                            .foregroundStyle(missing > 0 ? .orange : .secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    if showTakes {
                        ForEach(0 ..< info.numTakes, id: \.self) { i in
                            let hex = String(format: "%08x", i + 1)
                            let present = foundNames.contains(hex)
                            let interleaved: UInt32 = i < info.takeSizes.count ? info.takeSizes[i] : 0
                            let frames = interleaved / UInt32(ch)
                            let dur = sr > 0 ? formatDuration(Double(frames) / sr) : "?"
                            GridRow {
                                Text("take \(i + 1)").foregroundStyle(.secondary)
                                Text(present ? dur : "—").monospacedDigit()
                                Group {
                                    if present {
                                        Image(systemName: "checkmark").foregroundStyle(.tertiary)
                                    } else {
                                        Text("missing").foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Input").font(.caption.bold())
        }
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

    // MARK: - Output summary

    func outputSummary(sessionDir: URL) -> some View {
        let pairs          = vm.effectivePairs
        let names          = vm.snapInfo?.channelNames ?? [:]
        let total          = vm.sessionInfo?.numChannels ?? 0
        let pairedChannels = Set(pairs.flatMap { [$0.left, $0.right] })
        let monoCount      = total - pairedChannels.count
        let stereoCount    = pairs.count
        let markerCount    = vm.sessionInfo?.markerSamples.count ?? 0

        var rows: [OutputRow] = []
        for pair in pairs {
            let l = names[pair.left] ?? ""
            let r = names[pair.right] ?? ""
            let nameStr = [l, r].filter { !$0.isEmpty }.joined(separator: "/")
            rows.append(OutputRow(
                id: pair.left,
                chLabel: String(format: "ch%02d–%02d", pair.left, pair.right),
                nameLabel: nameStr,
                kind: .stereo(left: pair.left)
            ))
        }
        if total > 0 {
            for ch in 1 ... total where !pairedChannels.contains(ch) {
                let nextFree = ch + 1 <= total && !pairedChannels.contains(ch + 1)
                rows.append(OutputRow(
                    id: ch,
                    chLabel: String(format: "ch%02d", ch),
                    nameLabel: names[ch] ?? "",
                    kind: nextFree ? .monoLinkable(ch: ch) : .mono
                ))
            }
        }
        let sortedRows = rows.sorted { $0.id < $1.id }

        return GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if stereoCount > 0 {
                        Text("\(monoCount) mono + \(stereoCount) stereo").bold()
                    } else {
                        Text("\(monoCount > 0 ? monoCount : total) mono").bold()
                    }
                    if vm.isCustomized {
                        Spacer()
                        Button("Reset") { vm.resetPairs() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                if !sortedRows.isEmpty {
                    ScrollView(.vertical) {
                        Grid(horizontalSpacing: 6, verticalSpacing: 2) {
                            ForEach(sortedRows) { row in
                                GridRow {
                                    linkButton(for: row)
                                    Text(row.chLabel).gridColumnAlignment(.leading)
                                    Text(row.nameLabel)
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                } else if total > 0 {
                    Text("ch01–\(String(format: "%02d", total))").foregroundStyle(.secondary)
                }
                if markerCount > 0 {
                    Text("\(markerCount) markers (WAV cue, CSV, MIDI)").foregroundStyle(.secondary)
                }
                Text("Silent channels will be skipped automatically.").foregroundStyle(.tertiary)

                Divider().padding(.vertical, 2)

                HStack(spacing: 4) {
                    Text("Destination").foregroundStyle(.secondary)
                    Text(displayPath(vm.customOutputDir ?? vm.defaultOutputDir(for: sessionDir)))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseOutputDir(sessionDir: sessionDir) }
                    if vm.customOutputDir != nil {
                        Button {
                            vm.customOutputDir = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle("Use short filenames", isOn: $vm.shortFilenames)
                    .toggleStyle(.checkbox)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Output").font(.caption.bold())
        }
    }

    @ViewBuilder
    private func linkButton(for row: OutputRow) -> some View {
        switch row.kind {
        case .stereo(let left):
            Button { vm.unlinkPair(left: left) } label: {
                Image(systemName: "link")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Split into two mono channels")
        case .monoLinkable(let ch):
            Button { vm.linkChannels(ch, ch + 1) } label: {
                Image(systemName: "link")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Link with ch\(String(format: "%02d", ch + 1)) as a stereo pair")
        case .mono:
            Image(systemName: "link").opacity(0)
        }
    }

    // MARK: - Snap section

    @ViewBuilder
    func snapSection(sessionDir: URL) -> some View {
        GroupBox {
            if let snap = vm.snapInfo {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.snapName ?? "Wing snapshot")
                            .font(.caption.bold())
                        HStack(spacing: 8) {
                            if !snap.stereoPairs.isEmpty {
                                let pairs = snap.stereoPairs.map { "\($0.left):\($0.right)" }
                                    .joined(separator: ", ")
                                let count = snap.stereoPairs.count
                                Text("\(count) stereo pair\(count == 1 ? "" : "s"): \(pairs)")
                            } else {
                                Text("No stereo pairs")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if snap.channelNames.count > 0 {
                            Text("\(snap.channelNames.count) named channels")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Replace…") { browseSnap() }
                        .font(.caption)
                    Button {
                        vm.clearSnap()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wing snapshot")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("Drop a .snap file or browse to load stereo pairs and channel names")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Browse…") { browseSnap() }
                        .font(.caption)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleSnapDrop(providers)
        }
    }

    // MARK: - Drop & file handling

    func handlePendingURL() {
        guard let url = appDelegate.pendingURL else { return }
        appDelegate.pendingURL = nil
        if url.pathExtension.lowercased() == "snap" {
            vm.loadSnap(url: url)
        } else if url.hasDirectoryPath || isDirectory(url) {
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

    func browseSnap() {
        let panel = NSOpenPanel()
        panel.title = "Select Wing Snapshot"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Select a .snap file exported from the Wing console"
        if panel.runModal() == .OK, let url = panel.url,
           url.pathExtension.lowercased() == "snap" {
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
                if url.pathExtension.lowercased() == "snap" {
                    vm.loadSnap(url: url)
                } else if url.hasDirectoryPath || isDirectory(url) {
                    vm.loadSession(url: url)
                }
            }
        }
        return true
    }

    func handleSnapDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "snap"
            else { return }
            Task { @MainActor in
                vm.loadSnap(url: url)
            }
        }
        return true
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
