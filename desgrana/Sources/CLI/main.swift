// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore
// Platform backend (DesgranaCoreAudioToolbox / DesgranaCoreWav) is re-exported via Platform.swift

// MARK: - Minimal argument parsing (no dependencies)

struct CLIArgs {
    var sessionPath: String
    var outputPath: String?
    var prefix: String?
    var infoOnly: Bool
    var stereoPairs: [StereoPair]
    var snapURL: URL?
    var shortNames: Bool
    var dryRun: Bool

    // swiftlint:disable:next cyclomatic_complexity
    static func parse(_ args: [String]) -> CLIArgs {
        var sessionPath: String?
        var outputPath: String?
        var prefix: String?
        var infoOnly = false
        var stereoPairs: [StereoPair] = []
        var snapURL: URL?
        var shortNames = false
        var dryRun = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--info", "-i":
                infoOnly = true
            case "--output", "-o":
                i += 1
                guard i < args.count else { DesgranaCLI.fatal("--output requires a path") }
                outputPath = args[i]
            case "--prefix", "-p":
                i += 1
                guard i < args.count else { DesgranaCLI.fatal("--prefix requires a value") }
                prefix = args[i]
            case "--stereo", "-s":
                i += 1
                guard i < args.count else { DesgranaCLI.fatal("--stereo requires a value") }
                for pairStr in args[i].split(separator: ",") {
                    let parts = pairStr.split(separator: ":")
                    guard parts.count == 2, let l = Int(parts[0]), let r = Int(parts[1]), l > 0, r > 0 else {
                        DesgranaCLI.fatal("--stereo: invalid pair '\(pairStr)' — expected format 'L:R', e.g. 1:2")
                    }
                    stereoPairs.append(StereoPair(left: l, right: r))
                }
            case "--short-names":
                shortNames = true
            case "--dry-run":
                dryRun = true
            case "--snap":
                i += 1
                guard i < args.count else { DesgranaCLI.fatal("--snap requires a path") }
                snapURL = URL(fileURLWithPath: args[i])
            default:
                if args[i].hasPrefix("-") {
                    DesgranaCLI.fatal("Unknown option: \(args[i])")
                }
                sessionPath = args[i]
            }
            i += 1
        }
        guard let path = sessionPath else {
            DesgranaCLI.fatal("No session directory specified")
        }
        return CLIArgs(
            sessionPath: path,
            outputPath: outputPath,
            prefix: prefix,
            infoOnly: infoOnly,
            stereoPairs: stereoPairs,
            snapURL: snapURL,
            shortNames: shortNames,
            dryRun: dryRun
        )
    }
}

struct DesgranaCLI {
    // swiftlint:disable:next cyclomatic_complexity
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args.contains("-h") || args.contains("--help") {
            printUsage()
            return
        }

        let cliArgs = CLIArgs.parse(args)
        let path = cliArgs.sessionPath

        let inputURL = URL(fileURLWithPath: path)
        var isInputDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isInputDir) else {
            fatal("Not found: \(inputURL.path)")
        }

        // Resolve takes: a session folder (hex takes), a single WAV file, or a folder with
        // a single WAV (other recorders). A folder with several non-hex WAVs is refused.
        let takes: [URL]
        switch resolveSessionTakes(at: inputURL) {
        case .ok(let t):
            takes = t
        case .empty:
            takes = []
        case .ambiguous(let files):
            fatal("""
                Multiple WAV files in this folder — can't tell which to extract. \
                Pass a single .wav file, or a Behringer session folder with numbered takes. \
                Found: \(files.map { $0.lastPathComponent }.joined(separator: ", "))
                """, exitCode: 2)
        }

        // Directory used for SE_LOG/snap lookup and for naming. For a single file, it's its
        // parent; the base name is the file's name (so outputs are <name>_ch01.wav).
        let isFileInput = !isInputDir.boolValue
        let sessionDir = isFileInput ? inputURL.deletingLastPathComponent() : inputURL
        let baseName = isFileInput ? inputURL.deletingPathExtension().lastPathComponent
                                   : inputURL.lastPathComponent

        // Find SE_LOG.bin
        let selog = findSELog(in: sessionDir)
        var sessionInfo: SessionInfo?
        if let selogURL = selog {
            do {
                sessionInfo = try parseSELog(at: selogURL)
            } catch {
                warn("Could not parse SE_LOG.bin: \(error)")
            }
        }

        // Load snap (explicit --snap, or auto-detect in session dir)
        let resolvedSnapURL = cliArgs.snapURL ?? findConsoleSnapshot(in: sessionDir)
        var snapInfo: SnapInfo?
        if let url = resolvedSnapURL {
            do {
                snapInfo = try parseSnapOrScene(at: url)
                let src = cliArgs.snapURL != nil ? url.lastPathComponent : "\(url.lastPathComponent) (auto)"
                print("Snap: \(src) — \(snapInfo!.channelNames.count) named channels, \(snapInfo!.usbStereoPairs.count) USB stereo pairs")
            } catch {
                warn("Could not parse snap file: \(error)")
            }
        }

        // Stereo pairs: --stereo (manual override) > snap-derived (USB + L/R names) > all mono
        let activePairs: [StereoPair]
        if !cliArgs.stereoPairs.isEmpty {
            activePairs = cliArgs.stereoPairs
        } else if let snap = snapInfo, let info = sessionInfo {
            let numCh = info.numChannels
            let usbPairs = filterStereoPairs(snap.usbStereoPairs, channelCount: numCh)
            let usbTracks = Set(usbPairs.flatMap { [$0.left, $0.right] })
            let lclPairs = detectStereoPairsFromNames(snap.channelNames, channelCount: numCh)
                .filter { !usbTracks.contains($0.left) }
            activePairs = (usbPairs + lclPairs).sorted { $0.left < $1.left }
        } else {
            activePairs = []
        }
        var channelNames = snapInfo?.channelNames ?? [:]
        // No snap names: try track names embedded in the WAV (field recorders).
        // Placeholder today — parseIXMLTrackNames returns [:] until iXML parsing lands.
        if channelNames.isEmpty, let first = takes.first {
            channelNames = parseIXMLTrackNames(at: first)
        }

        // Takes status (used in both --info and split modes)
        let wavFiles = takes

        // Info-only mode
        if cliArgs.infoOnly {
            if let info = sessionInfo {
                printSessionInfo(info)
                printTakesStatus(info: info, found: wavFiles)
            } else {
                print("No SE_LOG.bin found. WAV files present:")
                for f in wavFiles { print("  \(f.lastPathComponent)") }
            }
            if !channelNames.isEmpty || !activePairs.isEmpty {
                print()
                printSnapSummary(names: channelNames, pairs: activePairs)
            }
            return
        }

        // Print session info
        if let info = sessionInfo {
            print("Session info (from SE_LOG.bin):")
            printSessionInfo(info)
            printTakesStatus(info: info, found: wavFiles)
            print()
        } else {
            warn("No SE_LOG.bin found. Will infer from WAV headers.")
            print()
        }

        // Determine output directory
        let outputDir: URL
        if let op = cliArgs.outputPath {
            outputDir = URL(fileURLWithPath: op, isDirectory: true)
        } else {
            // Sibling of the input, named <base>_extract (folder for a folder, in the
            // file's own directory for a single file).
            let container = isFileInput ? sessionDir : sessionDir.deletingLastPathComponent()
            outputDir = container.appendingPathComponent(baseName + "_extract")
        }

        // Determine prefix
        let pfx: String
        if let p = cliArgs.prefix {
            pfx = p
        } else if let info = sessionInfo, !info.sessionName.isEmpty {
            pfx = info.sessionName.replacingOccurrences(of: " ", with: "_") + "_"
        } else {
            pfx = baseName + "_"
        }

        // Dry-run: show what would be created without writing anything
        if cliArgs.dryRun {
            printDryRun(
                sessionInfo: sessionInfo,
                outputDir: outputDir,
                prefix: pfx,
                pairs: activePairs,
                channelNames: channelNames
            )
            return
        }

        // Split
        do {
            let result = try splitSession(
                sessionDir: sessionDir,
                outputDir: outputDir,
                prefix: pfx,
                stereoPairs: activePairs,
                channelNames: channelNames,
                useShortFilenames: cliArgs.shortNames,
                takes: wavFiles
            )

            // Embed per-channel track names (independent of markers)
            writeIXMLChunks(to: result.outputs)

            // Export markers
            if let info = sessionInfo, !info.markerSamples.isEmpty {
                writeCueChunks(to: result.outputs.map(\.url), markers: info.markerSamples)
                exportMarkers(info, to: outputDir, prefix: pfx)
                exportMIDIMarkers(info, to: outputDir, prefix: pfx)
            }

            printSplitSummary(
                keptMono: result.keptMono, keptStereo: result.keptStereo,
                silentCount: result.silentSkipped,
                totalFrames: result.totalFrames, sampleRate: result.sampleRate,
                outputDir: outputDir
            )
        } catch let err as SplitError {
            fatal(err.description, exitCode: err.exitCode)
        } catch {
            fatal("\(error)")
        }
    }

    // MARK: - Output helpers

    static func warn(_ message: String) {
        fputs("Warning: \(message)\n", stderr)
    }

    static func fatal(_ message: String, exitCode: Int32 = 1) -> Never {
        fputs("Error: \(message)\n", stderr)
        exit(exitCode)
    }

    // MARK: - Human-readable helpers

    static func findSELog(in dir: URL) -> URL? {
        for name in seLogCandidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func printTakesStatus(info: SessionInfo, found: [URL]) {
        let expected = info.numTakes
        let n = found.count
        let sr = Double(info.sampleRate)

        if n < expected {
            print("  Takes found  : \(n)/\(expected) — \(expected - n) missing")
        } else {
            print("  Takes found  : \(n)/\(expected) — complete")
        }

        let foundNames = Set(found.map { $0.deletingPathExtension().lastPathComponent.lowercased() })
        let ch = max(info.numChannels, 1)
        for i in 0 ..< expected {
            let hex = String(format: "%08x", i + 1)
            let isPresent = foundNames.contains(hex)
            let interleavedSamples = i < info.takeSizes.count ? info.takeSizes[i] : 0
            let frames = interleavedSamples / UInt32(ch)
            let duration = sr > 0 ? formatTime(Double(frames) / sr) : "?"
            let suffix = isPresent ? "" : "  [missing]"
            print("    Take \(i + 1) : \(duration)  (\(formatSamples(frames)) samples)\(suffix)")
        }
    }

    static func printSnapSummary(names: [Int: String], pairs: [StereoPair]) {
        if !pairs.isEmpty {
            print("  Stereo pairs :", pairs.map { "\($0.left):\($0.right)" }.joined(separator: ", "))
        }
        if !names.isEmpty {
            print("  Channel names:")
            for k in names.keys.sorted() {
                print("    ch\(String(format: "%02d", k)) : \(names[k]!)")
            }
        }
    }

    static func printDryRun(
        sessionInfo: SessionInfo?,
        outputDir: URL,
        prefix: String,
        pairs: [StereoPair],
        channelNames: [Int: String]
    ) {
        print("Dry run — no files will be written.")
        print("Output directory: \(outputDir.path)")
        print()
        let numCh = sessionInfo?.numChannels ?? 0
        guard numCh > 0 else { print("(channel count unknown — no SE_LOG.bin)"); return }
        let (active, paired) = validateStereoPairs(pairs, channelCount: numCh)
        print("Files that would be created:")
        var files: [(ch: Int, name: String)] = []
        for pair in active {
            let suffix = channelNameSuffix(for: [pair.left, pair.right], names: channelNames)
            files.append((pair.left, String(format: "%@ch%02d-%02d\(suffix).wav", prefix, pair.left, pair.right)))
        }
        for ch in 1...numCh where !paired.contains(ch) {
            let suffix = channelNameSuffix(for: [ch], names: channelNames)
            files.append((ch, String(format: "%@ch%02d\(suffix).wav", prefix, ch)))
        }
        for (_, name) in files.sorted(by: { $0.ch < $1.ch }) {
            print("  \(name)")
        }
    }

    static func printUsage() {
        let usage = """
        desgrana — Extract channels from Behringer Wing/X-Live multichannel WAV sessions into mono files.

        USAGE:
            desgrana <session-dir> [options]

        OPTIONS:
            --output, -o <path>     Output directory (default: <session-dir>_extract/)
            --prefix, -p <string>   Prefix for output filenames
            --stereo, -s <pairs>    Stereo pairs, e.g. 1:2,3:4 (overrides snap-derived pairs)
            --snap   <file>         Console snapshot (.snap Wing / .scn X32) for channel names and USB stereo pairs
            --short-names           Use channel name only for filenames (e.g. KICK.wav, not prefix_ch01_KICK.wav)
            --dry-run               Show what would be extracted without writing any files
            --info,   -i            Show session info only, without extracting
            --help,   -h            Show this help

        EXIT CODES:
            0    Success
            1    Bad arguments or session directory not found
            2    Filesystem error (cannot read input or write output)
            3    Format error (invalid WAV, channel count mismatch between takes)

        EXAMPLES:
            desgrana /Volumes/SD/X_LIVE/4B5C62B0
            desgrana /Volumes/SD/X_LIVE/4B5C62B0 --info
            desgrana /Volumes/SD/X_LIVE/4B5C62B0 --snap ~/MyShow.snap
            desgrana /Volumes/SD/X_LIVE/4B5C62B0 -o ~/Desktop/extract

        The session directory should contain:
            SE_LOG.BIN          Session metadata (markers, channel count, etc.)
            MyShow.snap         Wing snapshot (optional — stereo pairs + channel names)
            MyShow.scn          X32 scene file (alternative to .snap)
            00000001.wav        First WAV take (multichannel, 32-bit PCM)
            00000002.wav        Second WAV take (if recording exceeded 4GB)
            ...
        """
        print(usage)
    }
}

// Entry point
DesgranaCLI.main()
