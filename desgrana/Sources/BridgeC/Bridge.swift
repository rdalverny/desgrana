// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore
import DesgranaCoreWav

// MARK: - Probe

/// Scans a session directory and fills basic metadata.
/// Returns 0 on success, -1 if no WAV takes are found (fills errBuf).
@_cdecl("desgrana_probe")
public func desgrana_probe(
    _ sessionPath: UnsafePointer<CChar>,
    _ outChannels: UnsafeMutablePointer<Int32>,
    _ outDuration: UnsafeMutablePointer<Double>,
    _ sceneNameBuf: UnsafeMutablePointer<CChar>?,
    _ sceneNameLen: Int32,
    _ outPairLefts: UnsafeMutablePointer<Int32>?,
    _ outPairRights: UnsafeMutablePointer<Int32>?,
    _ pairCapacity: Int32,
    _ outPairCount: UnsafeMutablePointer<Int32>?,
    _ outChKeys: UnsafeMutablePointer<Int32>?,
    _ outChNames: UnsafeMutablePointer<CChar>?,
    _ chCapacity: Int32,
    _ outChCount: UnsafeMutablePointer<Int32>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int32,
    _ outSnapFound: UnsafeMutablePointer<Int32>?
) -> Int32 {
    let input = URL(fileURLWithPath: String(cString: sessionPath))

    // Resolve a folder (hex takes) or a single WAV file (other recorders).
    // SE_LOG/snap live next to the takes, so look them up in the containing directory.
    let resolved = resolveSessionTakes(at: input)
    if case .ambiguous = resolved {
        cStringCopy("Several WAV files here. Drop a single file, or a session folder.",
                    into: errBuf, maxLen: Int(errLen))
        return -1
    }
    let takes: [URL] = { if case .ok(let t) = resolved { return t } else { return [] } }()
    if takes.isEmpty {
        cStringCopy("No WAV takes found", into: errBuf, maxLen: Int(errLen))
        return -1
    }

    let dir = sessionDirectory(from: input)

    let selogURL = seLogCandidates
        .map { dir.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }

    let session = selogURL.flatMap { try? parseSELog(at: $0) }
    // No SE_LOG: recover channel count and duration from the first WAV header.
    let header = session == nil ? takes.first.flatMap { probeWavHeader(at: $0) } : nil
    outChannels.pointee = Int32(session?.numChannels ?? header?.channels ?? 0)
    outDuration.pointee = session?.totalDuration ?? header?.duration ?? 0

    let snap = findConsoleSnapshot(in: dir).flatMap { try? parseSnapOrScene(at: $0) }
    outSnapFound?.pointee = snap != nil ? 1 : 0

    if let buf = sceneNameBuf, sceneNameLen > 1 {
        // Only fill when the snap provides a non-empty scene name.
        // Callers are responsible for generating a fallback (e.g. NONAME_) when empty.
        let name = snap.flatMap { $0.sceneName.flatMap { $0.isEmpty ? nil : $0 } } ?? ""
        cStringCopy(name, into: buf, maxLen: Int(sceneNameLen))
    }

    if let pL = outPairLefts, let pR = outPairRights, let pC = outPairCount, pairCapacity > 0 {
        let pairs = detectStereoPairsFromNames(snap?.channelNames ?? [:], channelCount: Int(outChannels.pointee))
        let n = min(pairs.count, Int(pairCapacity))
        for i in 0..<n {
            pL[i] = Int32(pairs[i].left)
            pR[i] = Int32(pairs[i].right)
        }
        pC.pointee = Int32(n)
    }

    let chNameMax = 64
    if let keys = outChKeys, let buf = outChNames, let cnt = outChCount, chCapacity > 0 {
        // No snap: fall back to track names embedded in the WAV (iXML), like macOS does.
        let chNames = snap?.channelNames
            ?? (takes.first.map { parseIXMLTrackNames(at: $0) } ?? [:])
        let sorted = chNames.sorted { $0.key < $1.key }
        let n = min(sorted.count, Int(chCapacity))
        for i in 0..<n {
            keys[i] = Int32(sorted[i].key)
            cStringCopy(sorted[i].value, into: buf.advanced(by: i * chNameMax), maxLen: chNameMax)
        }
        cnt.pointee = Int32(n)
    }

    return 0
}

// MARK: - Split

/// Splits a session directory into per-channel WAV files.
/// stereoPairs: parallel arrays of left/right channel numbers (1-indexed), length pairCount.
/// channelNames: parallel arrays of channel numbers and name strings, length chNameCount.
/// progressCb: called with (currentTake, totalTakes, userData) after each take; may be NULL.
/// Returns 0 on success, -1 on error (fills errBuf).
@_cdecl("desgrana_split")
// swiftlint:disable cyclomatic_complexity
public func desgrana_split(
    _ sessionPath: UnsafePointer<CChar>,
    _ outputPath: UnsafePointer<CChar>,
    _ prefix: UnsafePointer<CChar>?,
    _ pairLefts: UnsafePointer<Int32>?,
    _ pairRights: UnsafePointer<Int32>?,
    _ pairCount: Int32,
    _ chNameKeys: UnsafePointer<Int32>?,
    _ chNameValues: UnsafePointer<UnsafePointer<CChar>?>?,
    _ chNameCount: Int32,
    _ progressCb: (@convention(c) (Int32, Int32, Double, UnsafeMutableRawPointer?) -> Void)?,
    _ userData: UnsafeMutableRawPointer?,
    _ outSilentSkipped: UnsafeMutablePointer<Int32>?,
    _ outKeptMono: UnsafeMutablePointer<Int32>?,
    _ outKeptStereo: UnsafeMutablePointer<Int32>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int32
) -> Int32 {
    let input      = URL(fileURLWithPath: String(cString: sessionPath))
    let outputDir  = URL(fileURLWithPath: String(cString: outputPath))
    let pfx        = prefix.map { String(cString: $0) } ?? ""

    // Resolve a folder (hex takes) or a single WAV file (other recorders).
    // SE_LOG lives next to the takes, so use the containing directory for its lookup.
    let resolved = resolveSessionTakes(at: input)
    guard case .ok(let takes) = resolved else {
        let msg = { if case .ambiguous = resolved {
            return "Several WAV files here. Drop a single file, or a session folder."
        } else { return "No WAV takes found" } }()
        cStringCopy(msg, into: errBuf, maxLen: Int(errLen))
        return -1
    }
    let sessionDir = sessionDirectory(from: input)

    var pairs: [StereoPair] = []
    if let lefts = pairLefts, let rights = pairRights, pairCount > 0 {
        for i in 0..<Int(pairCount) {
            pairs.append(StereoPair(left: Int(lefts[i]), right: Int(rights[i])))
        }
    }

    var names: [Int: String] = [:]
    if let keys = chNameKeys, let vals = chNameValues, chNameCount > 0 {
        for i in 0..<Int(chNameCount) {
            if let v = vals[i] { names[Int(keys[i])] = String(cString: v) }
        }
    }

    // Build per-take frame offsets from SE_LOG for deterministic progress.
    let selogURL = seLogCandidates
        .lazy.map { sessionDir.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    let seInfo = selogURL.flatMap { try? parseSELog(at: $0) }
    let totalFrames = Double(seInfo?.totalLength ?? 0)
    let numCh = max(seInfo?.numChannels ?? 1, 1)
    var framesBeforeTake: [Int: Double] = [:]
    if let info = seInfo {
        var acc: Double = 0
        for i in 0 ..< info.takeSizes.count {
            framesBeforeTake[i + 1] = acc
            acc += Double(info.takeSizes[i]) / Double(numCh)
        }
    }

    do {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let result = try splitSession(
            sessionDir: sessionDir,
            outputDir: outputDir,
            prefix: pfx,
            stereoPairs: pairs,
            channelNames: names,
            useShortFilenames: pfx.isEmpty,
            takes: takes,
            progress: { take, total, framesInTake in
                let fraction: Double
                if totalFrames > 0 {
                    let before = framesBeforeTake[take] ?? 0
                    fraction = min((before + Double(framesInTake)) / totalFrames, 1.0)
                } else {
                    fraction = total > 0 ? Double(take - 1) / Double(total) : 0
                }
                progressCb?(Int32(take), Int32(total), fraction, userData)
            }
        )
        writeIXMLChunks(to: result.outputs)
        writeBextChunks(to: result.outputs, source: takes.first,
                        sampleRate: seInfo?.sampleRate ?? Int(result.sampleRate))
        if let p = outSilentSkipped { p.pointee = Int32(result.silentSkipped) }
        if let p = outKeptMono      { p.pointee = Int32(result.keptMono) }
        if let p = outKeptStereo    { p.pointee = Int32(result.keptStereo) }
        return 0
    } catch {
        cStringCopy("\(error)", into: errBuf, maxLen: Int(errLen))
        return -1
    }
}
// swiftlint:enable cyclomatic_complexity

// MARK: - Load snap

/// Parses a single .snap or .scn file and fills snap metadata (scene name, pairs, channel names).
/// Returns 0 on success, -1 if the file cannot be parsed.
@_cdecl("desgrana_load_snap")
public func desgrana_load_snap(
    _ snapPath: UnsafePointer<CChar>,
    _ sceneNameBuf: UnsafeMutablePointer<CChar>?,
    _ sceneNameLen: Int32,
    _ outPairLefts: UnsafeMutablePointer<Int32>?,
    _ outPairRights: UnsafeMutablePointer<Int32>?,
    _ pairCapacity: Int32,
    _ outPairCount: UnsafeMutablePointer<Int32>?,
    _ outChKeys: UnsafeMutablePointer<Int32>?,
    _ outChNames: UnsafeMutablePointer<CChar>?,
    _ chCapacity: Int32,
    _ outChCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    let url = URL(fileURLWithPath: String(cString: snapPath))
    guard let snap = try? parseSnapOrScene(at: url) else { return -1 }

    if let buf = sceneNameBuf, sceneNameLen > 1 {
        cStringCopy(snap.sceneName ?? "", into: buf, maxLen: Int(sceneNameLen))
    }

    if let pL = outPairLefts, let pR = outPairRights, let pC = outPairCount, pairCapacity > 0 {
        let pairs = detectStereoPairsFromNames(snap.channelNames, channelCount: snap.channelNames.keys.max() ?? 0)
        let n = min(pairs.count, Int(pairCapacity))
        for i in 0..<n { pL[i] = Int32(pairs[i].left); pR[i] = Int32(pairs[i].right) }
        pC.pointee = Int32(n)
    }

    let chNameMax = 64
    if let keys = outChKeys, let buf = outChNames, let cnt = outChCount, chCapacity > 0 {
        let sorted = snap.channelNames.sorted { $0.key < $1.key }
        let n = min(sorted.count, Int(chCapacity))
        for i in 0..<n {
            keys[i] = Int32(sorted[i].key)
            cStringCopy(sorted[i].value, into: buf.advanced(by: i * chNameMax), maxLen: chNameMax)
        }
        cnt.pointee = Int32(n)
    }

    return 0
}

// MARK: - Update check

/// Fetches the remote version feed and reports the result via `callback`.
/// Designed to be called from a background thread — blocks until the HTTP
/// response is received (or times out / errors).
///
/// `callback` is invoked exactly once:
///   - latest / notes / url are non-nil when a newer version is available.
///   - All three are nil when the current version is up to date (or on error).
@_cdecl("desgrana_check_update")
public func desgrana_check_update(
    _ current: UnsafePointer<CChar>,
    _ callback: @convention(c) (
        UnsafePointer<CChar>?,   // latest version, or nil
        UnsafePointer<CChar>?,   // release notes, or nil
        UnsafePointer<CChar>?,   // release URL, or nil
        UnsafeMutableRawPointer? // user_data
    ) -> Void,
    _ userData: UnsafeMutableRawPointer?
) {
    let currentStr = String(cString: current)
    // Convert async → sync. The box + semaphore pattern is intentional:
    // the semaphore provides the memory barrier that makes the write in the
    // Task visible to the read below.
    final class Box: @unchecked Sendable { var value: UpdateInfo? }
    let box  = Box()
    let sema = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await fetchUpdate(current: currentStr)
        sema.signal()
    }
    sema.wait()

    guard let info = box.value else {
        callback(nil, nil, nil, userData)
        return
    }
    info.version.withCString { versionPtr in
        info.notes.withCString { notesPtr in
            let urlStr = info.url?.absoluteString ?? ""
            urlStr.withCString { urlPtr in
                callback(versionPtr, notesPtr, urlStr.isEmpty ? nil : urlPtr, userData)
            }
        }
    }
}

// MARK: - DAW session export

/// Generates a DAW session file (Reaper / Ardour / Audacity) referencing the WAVs
/// already extracted in `outputDir`. Channels and sample rate are read from the WAV
/// headers via cross-platform RIFF parsing (no AVFoundation on Linux). Markers are
/// optional. On success writes the generated file's path into `outSessionPath` and
/// returns 0; returns -1 on error (fills errBuf).
@_cdecl("desgrana_export_daw_session")
public func desgrana_export_daw_session(
    _ outputDir: UnsafePointer<CChar>,
    _ sessionDir: UnsafePointer<CChar>?,
    _ dawKind: Int32,
    _ durationSec: Double,
    _ outSessionPath: UnsafeMutablePointer<CChar>?,
    _ outPathLen: Int32,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int32
) -> Int32 {
    let dir = URL(fileURLWithPath: String(cString: outputDir))

    // Collect extracted WAVs in sorted filename order (matches the macOS path).
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    let wavURLs = contents
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !wavURLs.isEmpty else {
        cStringCopy("no WAV files in output directory", into: errBuf, maxLen: Int(errLen))
        return -1
    }

    // Channels per WAV + session sample rate from the first WAV (RIFF, cross-platform).
    var wavs: [(url: URL, channels: Int)] = []
    var sampleRate = 48_000.0
    for (i, url) in wavURLs.enumerated() {
        let header = probeWavHeader(at: url)
        wavs.append((url, max(header?.channels ?? 1, 1)))
        if i == 0, let sr = header?.sampleRate, sr > 0 { sampleRate = sr }
    }

    // Markers from the session's SE_LOG (position = sample / sampleRate, "Marker N"),
    // matching the macOS app. The output dir holds only WAVs, so read the session dir.
    var markers: [(time: Double, name: String)] = []
    if let sp = sessionDir {
        let sdir = sessionDirectory(from: URL(fileURLWithPath: String(cString: sp)))
        let selogURL = seLogCandidates
            .lazy.map { sdir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let info = selogURL.flatMap({ try? parseSELog(at: $0) }), !info.markerSamples.isEmpty {
            let sr = Double(info.sampleRate > 0 ? info.sampleRate : 48_000)
            markers = info.markerSamples.enumerated().map { i, s in
                (time: Double(s) / sr, name: "Marker \(i + 1)")
            }
        }
    }

    do {
        let generated: URL
        switch dawKind {
        case 0:
            generated = try generateRPP(wavs: wavs, duration: durationSec,
                                        sampleRate: sampleRate, markers: markers, outputDir: dir)
        case 1:
            generated = try generateArdourSession(wavs: wavs, duration: durationSec,
                                                  sampleRate: sampleRate, markers: markers, outputDir: dir)
        case 2:
            generated = try generateAudacityLOF(wavs: wavs, duration: durationSec,
                                                sampleRate: sampleRate, markers: markers, outputDir: dir)
        default:
            cStringCopy("unknown DAW kind \(dawKind)", into: errBuf, maxLen: Int(errLen))
            return -1
        }
        cStringCopy(generated.path, into: outSessionPath, maxLen: Int(outPathLen))
        return 0
    } catch {
        cStringCopy("\(error)", into: errBuf, maxLen: Int(errLen))
        return -1
    }
}

// MARK: - Helpers

/// Returns `url` if it is a directory, otherwise its parent directory.
private func sessionDirectory(from url: URL) -> URL {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return (exists && isDir.boolValue) ? url : url.deletingLastPathComponent()
}

private func cStringCopy(_ str: String, into buf: UnsafeMutablePointer<CChar>?, maxLen: Int) {
    guard let buf = buf, maxLen > 1 else { return }
    let bytes = Array(str.utf8.prefix(maxLen - 1)) + [0]
    bytes.withUnsafeBytes { UnsafeMutableRawPointer(buf).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
}
