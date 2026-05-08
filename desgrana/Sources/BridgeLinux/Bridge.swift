// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore
import DesgranaCoreLinux

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
    _ errLen: Int32
) -> Int32 {
    let dir = URL(fileURLWithPath: String(cString: sessionPath))

    let selogURL = ["SE_LOG.BIN", "se_log.bin", "SE_LOG.bin"]
        .map { dir.appendingPathComponent($0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }

    let session = selogURL.flatMap { try? parseSELog(at: $0) }
    outChannels.pointee = Int32(session?.numChannels ?? 0)
    outDuration.pointee = session?.totalDuration ?? 0

    let snap = findSnap(in: dir).flatMap { try? parseSnap(at: $0) }

    if let buf = sceneNameBuf, sceneNameLen > 1 {
        let name: String
        if let scene = snap?.sceneName, !scene.isEmpty {
            name = scene
        } else if let sn = session?.sessionName, !sn.isEmpty,
                  sn.range(of: #"^[0-9A-F]{8}$"#, options: .regularExpression) == nil {
            name = sn
        } else {
            name = dir.lastPathComponent
        }
        cStringCopy(name, into: buf, maxLen: Int(sceneNameLen))
    }

    if let pL = outPairLefts, let pR = outPairRights, let pC = outPairCount, pairCapacity > 0 {
        let pairs = filterStereoPairs(snap?.stereoPairs ?? [], channelCount: Int(outChannels.pointee))
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
    _ progressCb: (@convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void)?,
    _ userData: UnsafeMutableRawPointer?,
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

    do {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        _ = try splitSession(
            sessionDir: sessionDir,
            outputDir: outputDir,
            prefix: pfx,
            stereoPairs: pairs,
            channelNames: names,
            useShortFilenames: pfx.isEmpty,
            progress: { take, total, _ in progressCb?(Int32(take), Int32(total), userData) }
        )
        return 0
    } catch {
        cStringCopy("\(error)", into: errBuf, maxLen: Int(errLen))
        return -1
    }
}

// MARK: - Helpers

private func cStringCopy(_ str: String, into buf: UnsafeMutablePointer<CChar>?, maxLen: Int) {
    guard let buf = buf, maxLen > 1 else { return }
    let bytes = Array(str.prefix(maxLen - 1).utf8) + [0]
    bytes.withUnsafeBytes { UnsafeMutableRawPointer(buf).copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
}
