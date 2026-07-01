// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore
// Platform backend (DesgranaCoreAudioToolbox / DesgranaCoreWav) is re-exported via Platform.swift
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    var json: Bool

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
        var json = false
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
            case "--json":
                json = true
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
            dryRun: dryRun,
            json: json
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
        // For a single file, the base name is the file's name (so outputs are <name>_ch01.wav).
        let isFileInput = !isInputDir.boolValue
        let baseName = isFileInput ? inputURL.deletingPathExtension().lastPathComponent
                                   : inputURL.lastPathComponent

        // Load via Core's Session — same orchestration (takes, SE_LOG, snap, pair derivation)
        // as the macOS app and the Qt bridge.
        var session: Session
        let sessionDir: URL
        switch Session.load(input: inputURL) {
        case .ok(let s, let dir):
            session = s
            sessionDir = dir
        case .empty:
            fatal("No WAV take files found in: \(inputURL.path)", exitCode: 2)
        case .ambiguous(let files):
            fatal("""
                Multiple WAV files in this folder — can't tell which to extract. \
                Pass a single .wav file, or a Behringer session folder with numbered takes. \
                Found: \(files.map { $0.lastPathComponent }.joined(separator: ", "))
                """, exitCode: 2)
        }
        if session.sessionInfo == nil, let selog = findSELog(in: sessionDir) {
            warn("SE_LOG.bin present but could not be parsed (\(selog.lastPathComponent))")
        }

        // Explicit --snap overrides the auto-detected snapshot (and suppresses it if invalid).
        if let snapURL = cliArgs.snapURL {
            if (try? parseSnapOrScene(at: snapURL)) != nil {
                session.loadSnap(url: snapURL)
            } else {
                warn("Could not parse snap file: \(snapURL.lastPathComponent)")
                session.snapInfo = nil
                session.snapName = nil
            }
        }
        if let snap = session.snapInfo, !cliArgs.json {
            let src = cliArgs.snapURL != nil ? (session.snapName ?? "") : "\(session.snapName ?? "") (auto)"
            print("Snap: \(src) — \(snap.channelNames.count) named channels, \(snap.usbStereoPairs.count) USB stereo pairs")
        }

        // Stereo pairs: --stereo (manual override) > snap-derived (USB + L/R names) > all mono.
        if !cliArgs.stereoPairs.isEmpty {
            session.userOverridePairs = cliArgs.stereoPairs
        }
        let activePairs = session.effectivePairs
        let channelNames = session.effectiveChannelNames

        let sessionInfo = session.sessionInfo
        let wavFiles = session.takes

        // Output directory: sibling <base>_extract, or the explicit --output path.
        func resolvedOutputDir() -> URL {
            if let op = cliArgs.outputPath { return URL(fileURLWithPath: op, isDirectory: true) }
            let container = isFileInput ? sessionDir : sessionDir.deletingLastPathComponent()
            return container.appendingPathComponent(baseName + "_extract")
        }
        // Prefix: --prefix, else the SE_LOG session name, else the base name.
        func resolvedPrefix() -> String {
            if let p = cliArgs.prefix { return p }
            if let info = sessionInfo, !info.sessionName.isEmpty {
                return info.sessionName.replacingOccurrences(of: " ", with: "_") + "_"
            }
            return baseName + "_"
        }

        // Emits a report as pure JSON on stdout (human/progress noise silenced by callers).
        func emitReport(result: SplitResult?, plannedSpecs: [OutputSpec]?, format: SourceFormat?) {
            let report = buildExtractionReport(
                session: session, sessionDir: sessionDir,
                outputDir: resolvedOutputDir(), prefix: resolvedPrefix(),
                shortNames: cliArgs.shortNames, isSingleFile: isFileInput,
                pairs: activePairs, channelNames: channelNames, result: result,
                plannedSpecs: plannedSpecs, format: format)
            print(report.jsonString())
        }

        // Info-only mode
        if cliArgs.infoOnly {
            if cliArgs.json {
                emitReport(result: nil, plannedSpecs: nil, format: wavFiles.first.flatMap(probeSourceFormat))
                return
            }
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
        if let info = sessionInfo, !cliArgs.json {
            print("Session info (from SE_LOG.bin):")
            printSessionInfo(info)
            printTakesStatus(info: info, found: wavFiles)
            print()
        } else if sessionInfo == nil, !cliArgs.json {
            warn("No SE_LOG.bin found. Will infer from WAV headers.")
            print()
        }

        let outputDir = resolvedOutputDir()
        let pfx = resolvedPrefix()

        // Dry-run: report what would be created without writing anything.
        if cliArgs.dryRun {
            let (activeVal, pairedVal) = validateStereoPairs(activePairs, channelCount: session.channelCount)
            let specs = buildOutputSpecs(
                activePairs: activeVal, pairedChannels: pairedVal, numChannels: session.channelCount,
                channelNames: channelNames, outputDir: outputDir, prefix: pfx,
                useShortFilenames: cliArgs.shortNames)
            if cliArgs.json {
                emitReport(result: nil, plannedSpecs: specs,
                           format: wavFiles.first.flatMap(probeSourceFormat))
            } else {
                printDryRun(sessionInfo: sessionInfo, outputDir: outputDir, prefix: pfx,
                            pairs: activePairs, channelNames: channelNames)
            }
            return
        }

        // Split
        do {
            // iXML track names + bext + cue (markers) are embedded before `data` at
            // file creation by splitSession; markers also get sidecar .txt/.mid exports.
            // In --json mode, splitSession's progress prints are silenced so stdout is pure JSON.
            let result = try withStdout(silenced: cliArgs.json) {
                let r = try splitSession(
                    sessionDir: sessionDir,
                    outputDir: outputDir,
                    prefix: pfx,
                    stereoPairs: activePairs,
                    channelNames: channelNames,
                    useShortFilenames: cliArgs.shortNames,
                    takes: wavFiles,
                    markers: sessionInfo?.markerSamples ?? []
                )
                if let info = sessionInfo, !info.markerSamples.isEmpty {
                    exportMarkers(info, to: outputDir, prefix: pfx)
                    exportMIDIMarkers(info, to: outputDir, prefix: pfx)
                }
                return r
            }

            if cliArgs.json {
                emitReport(result: result, plannedSpecs: nil, format: result.sourceFormat)
            } else {
                printSplitSummary(
                    keptMono: result.keptMono, keptStereo: result.keptStereo,
                    silentCount: result.silentSkipped,
                    totalFrames: result.totalFrames, sampleRate: result.sampleRate,
                    outputDir: outputDir
                )
            }
        } catch let err as SplitError {
            fatal(err.description, exitCode: err.exitCode)
        } catch {
            fatal("\(error)")
        }
    }

    /// Runs `body` with stdout redirected to /dev/null when `silenced` is true, restoring it
    /// afterwards. Used by --json so the split's progress prints never reach the JSON stream.
    static func withStdout<T>(silenced: Bool, _ body: () throws -> T) rethrows -> T {
        guard silenced else { return try body() }
        fflush(stdout)
        let saved = dup(1)
        let devnull = open("/dev/null", O_WRONLY)
        if devnull >= 0 { dup2(devnull, 1) }
        defer {
            fflush(stdout)
            if devnull >= 0 { dup2(saved, 1); close(devnull) }
            close(saved)
        }
        return try body()
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
            --json                  Print a machine-readable JSON report on stdout (pairs with --dry-run / --info)
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
