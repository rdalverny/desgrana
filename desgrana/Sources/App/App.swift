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

// MARK: - Cursor modifier

struct RowCursorModifier: ViewModifier {
    let kind: OutputRow.Kind
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(pointerStyle15)
        } else {
            content
        }
    }
    @available(macOS 15, *)
    private var pointerStyle15: PointerStyle {
        switch kind {
        case .stereo:                          return .columnResize
        case .monoLinkable, .monoLinkablePrev: return .link
        case .mono:                            return .default
        }
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = SplitViewModel()
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var isTargeted = false
    @State private var hoveredGroupIDs: Set<Int> = []
    @State private var sessionNameHovered = false
    @State private var destHovered = false
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

    // MARK: - Ready view

    func readyView(sessionDir: URL) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                TextField("Session name", text: $vm.sessionName)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                trackListView
                    .padding(.horizontal, -4)
                statusLine(sessionDir: sessionDir)
                    .padding(.bottom, 6)
                destinationLine(sessionDir: sessionDir)

                if vm.snapInfo == nil {
                    Button { browseSnap() } label: {
                        Label("Add Wing snapshot…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
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

    // MARK: - Track list

    private func buildRows() -> [OutputRow] {
        let pairs          = vm.effectivePairs
        let names          = vm.snapInfo?.channelNames ?? [:]
        let total          = vm.sessionInfo?.numChannels ?? 0
        let pairedChannels = Set(pairs.flatMap { [$0.left, $0.right] })
        var rows: [OutputRow] = []

        for pair in pairs {
            let l = names[pair.left] ?? ""
            let r = names[pair.right] ?? ""
            let nameStr = [l, r].filter { !$0.isEmpty }.joined(separator: " & ")
            rows.append(OutputRow(
                id: pair.left,
                chLabel: String(format: "ch %02d–%02d", pair.left, pair.right),
                nameLabel: nameStr,
                kind: .stereo(left: pair.left)
            ))
        }
        if total > 0 {
            for ch in 1...total where !pairedChannels.contains(ch) {
                let nextFree = ch + 1 <= total && !pairedChannels.contains(ch + 1)
                let prevFree = ch - 1 >= 1 && !pairedChannels.contains(ch - 1)
                let kind: OutputRow.Kind = nextFree ? .monoLinkable(ch: ch)
                    : prevFree ? .monoLinkablePrev(ch: ch)
                    : .mono
                rows.append(OutputRow(
                    id: ch,
                    chLabel: String(format: "ch %02d", ch),
                    nameLabel: names[ch] ?? "",
                    kind: kind
                ))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }

    var trackListView: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 6)
                ForEach(buildRows()) { row in
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Group {
                            switch row.kind {
                            case .stereo: Text("stereo")
                            default:      Text("mono")
                            }
                        }
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                        .padding(.leading, 3)
                        Text(row.nameLabel.isEmpty ? row.chLabel : row.nameLabel)
                            .foregroundStyle(row.nameLabel.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.chLabel)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.tertiary)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoveredGroupIDs.contains(row.id) ? Color.primary.opacity(0.06) : Color.clear)
                            .padding(.leading, -4)
                            .padding(.trailing, -4)
                    )
                    .modifier(RowCursorModifier(kind: row.kind))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        switch row.kind {
                        case .stereo(let left): vm.unlinkPair(left: left)
                        case .monoLinkable(let ch): vm.linkChannels(ch, ch + 1)
                        case .monoLinkablePrev(let ch): vm.linkChannels(ch - 1, ch)
                        case .mono: break
                        }
                    }
                    .onHover { hovered in
                        guard hovered else { return }
                        switch row.kind {
                        case .stereo:
                            hoveredGroupIDs = [row.id]
                        case .monoLinkable(let ch):
                            hoveredGroupIDs = [ch, ch + 1]
                        case .monoLinkablePrev(let ch):
                            hoveredGroupIDs = [ch - 1, ch]
                        case .mono:
                            hoveredGroupIDs = []
                        }
                    }
                    .help({
                        switch row.kind {
                        case .stereo: return "Click to split into two mono channels"
                        case .monoLinkable(let ch): return "Click to pair with ch\(String(format: "%02d", ch + 1)) as stereo"
                        case .monoLinkablePrev(let ch): return "Click to pair with ch\(String(format: "%02d", ch - 1)) as stereo"
                        case .mono: return ""
                        }
                    }())
                }
                Color.clear.frame(height: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { if !$0 { hoveredGroupIDs = [] } }
        }
        .frame(maxHeight: 200)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
        VStack(alignment: .leading, spacing: 4) {
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
                Text(String(displayPath(vm.customOutputDir ?? vm.defaultOutputDir(for: sessionDir)).prefix(300)))
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
