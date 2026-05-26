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
    let dir = URL(fileURLWithPath: String(cString: sessionPath))

    let selogURL = ["SE_LOG.BIN", "se_log.bin", "SE_LOG.bin"]
        .map { dir.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }

    let session = selogURL.flatMap { try? parseSELog(at: $0) }
    outChannels.pointee = Int32(session?.numChannels ?? 0)
    outDuration.pointee = session?.totalDuration ?? 0

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
        let chNames = snap?.channelNames ?? [:]
        let sorted = chNames.sorted { $0.key < $1.key }
        let n = min(sorted.count, Int(chCapacity))
        for i in 0..<n {
            keys[i] = Int32(sorted[i].key)
            cStringCopy(sorted[i].value, into: buf.advanced(by: i * chNameMax), maxLen: chNameMax)
        }
        cnt.pointee = Int32(n)
    }

    if findWavTakes(in: dir).isEmpty {
        cStringCopy("No WAV takes found", into: errBuf, maxLen: Int(errLen))
        return -1
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
    let sessionDir = URL(fileURLWithPath: String(cString: sessionPath))
    let outputDir  = URL(fileURLWithPath: String(cString: outputPath))
    let pfx        = prefix.map { String(cString: $0) } ?? ""

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
    let selogURL = ["SE_LOG.BIN", "se_log.bin", "SE_LOG.bin"]
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

// MARK: - Helpers

private func cStringCopy(_ str: String, into buf: UnsafeMutablePointer<CChar>?, maxLen: Int) {
    guard let buf = buf, maxLen > 1 else { return }
    let bytes = Array(str.utf8.prefix(maxLen - 1)) + [0]
    bytes.withUnsafeBytes { UnsafeMutableRawPointer(buf).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
}
