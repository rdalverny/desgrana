// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore
// Platform backend (DesgranaCoreMac / DesgranaCoreLinux) is re-exported via Platform.swift

// MARK: - Minimal argument parsing (no dependencies)

struct CLIArgs {
    var sessionPath: String
    var outputPath: String?
    var prefix: String?
    var infoOnly: Bool
    var stereoPairs: [StereoPair]
    var snapURL: URL?

    // swiftlint:disable:next cyclomatic_complexity
    static func parse(_ args: [String]) -> CLIArgs {
        var sessionPath: String?
        var outputPath: String?
        var prefix: String?
        var infoOnly = false
        var stereoPairs: [StereoPair] = []
        var snapURL: URL?
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
        guard let path = sessionPath else { DesgranaCLI.fatal("No session directory specified") }
        return CLIArgs(
            sessionPath: path,
            outputPath: outputPath,
            prefix: prefix,
            infoOnly: infoOnly,
            stereoPairs: stereoPairs,
            snapURL: snapURL
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

        let sessionDir = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            fatal("Directory not found: \(sessionDir.path)")
        }

        // Find SE_LOG.bin
        let selog = findSELog(in: sessionDir)
        var sessionInfo: SessionInfo?
        if let selogURL = selog {
            do {
                sessionInfo = try parseSELog(at: selogURL)
            } catch {
                print("Warning: Could not parse SE_LOG.bin: \(error)")
            }
        }

        // Load snap (explicit --snap, or auto-detect in session dir)
        let resolvedSnapURL = cliArgs.snapURL ?? findSnap(in: sessionDir)
        var snapInfo: SnapInfo?
        if let url = resolvedSnapURL {
            do {
                snapInfo = try parseSnap(at: url)
                let src = cliArgs.snapURL != nil ? url.lastPathComponent : "\(url.lastPathComponent) (auto)"
                print("Snap: \(src) — \(snapInfo!.channelNames.count) named channels, \(snapInfo!.stereoPairs.count) stereo pairs")
            } catch {
                print("Warning: Could not parse snap file: \(error)")
            }
        }

        // Stereo pairs: explicit --stereo takes priority over snap
        let activePairs: [StereoPair] =
            cliArgs.stereoPairs.isEmpty
            ? snapInfo?.stereoPairs ?? []
            : cliArgs.stereoPairs
        let channelNames = snapInfo?.channelNames ?? [:]

        // Takes status (used in both --info and split modes)
        let wavFiles = findWavTakes(in: sessionDir)

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
            print("Warning: No SE_LOG.bin found. Will infer from WAV headers.")
            print()
        }

        // Determine output directory
        let outputDir: URL
        if let op = cliArgs.outputPath {
            outputDir = URL(fileURLWithPath: op, isDirectory: true)
        } else {
            outputDir = sessionDir.deletingLastPathComponent()
                .appendingPathComponent(sessionDir.lastPathComponent + "_extract")
        }

        // Determine prefix
        let pfx: String
        if let p = cliArgs.prefix {
            pfx = p
        } else if let info = sessionInfo, !info.sessionName.isEmpty {
            pfx = info.sessionName.replacingOccurrences(of: " ", with: "_") + "_"
        } else {
            pfx = sessionDir.lastPathComponent + "_"
        }

        // Split
        do {
            let result = try splitSession(
                sessionDir: sessionDir,
                outputDir: outputDir,
                prefix: pfx,
                stereoPairs: activePairs,
                channelNames: channelNames
            )

            // Export markers
            if let info = sessionInfo, !info.markerSamples.isEmpty {
                writeCueChunks(to: result.urls, markers: info.markerSamples)
                exportMarkers(info, to: outputDir, prefix: pfx)
                exportMIDIMarkers(info, to: outputDir, prefix: pfx)
            }
        } catch {
            fatal("\(error)")
        }
    }

    // MARK: - Helpers

    static func findSELog(in dir: URL) -> URL? {
        // Try both cases
        for name in ["SE_LOG.BIN", "se_log.bin", "SE_LOG.bin"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func fatal(_ message: String) -> Never {
        fputs("Error: \(message)\n", stderr)
        exit(1)
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

    static func printUsage() {
        let usage = """
        desgrana — Extract channels from Behringer Wing/X-Live multichannel WAV sessions into mono files.

        USAGE:
            desgrana <session-dir> [options]

        OPTIONS:
            --output, -o <path>     Output directory (default: <session-dir>_extract/)
            --prefix, -p <string>   Prefix for output filenames
            --stereo, -s <pairs>    Stereo pairs, e.g. 1:2,3:4 (overrides --snap pairs)
            --snap   <file>         Wing snapshot (.snap) for stereo pairs and channel names
            --info,   -i            Show session info only, without extracting
            --help,   -h            Show this help

        EXAMPLES:
            desgrana /Volumes/SD/X_LIVE/4B5C62B0
            desgrana /Volumes/SD/X_LIVE/4B5C62B0 --info
            desgrana /Volumes/SD/X_LIVE/4B5C62B0 --snap ~/MyShow.snap
            desgrana /Volumes/SD/X_LIVE/4B5C62B0 -o ~/Desktop/extract

        The session directory should contain:
            SE_LOG.BIN          Session metadata (markers, channel count, etc.)
            MyShow.snap         Wing snapshot (optional — stereo pairs + channel names)
            00000001.wav        First WAV take (multichannel, 32-bit PCM)
            00000002.wav        Second WAV take (if recording exceeded 4GB)
            ...
        """
        print(usage)
    }
}

// Entry point
DesgranaCLI.main()
