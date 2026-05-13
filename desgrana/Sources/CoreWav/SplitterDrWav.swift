// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import CWav
import DesgranaCore

// MARK: - Internal track representation

private struct Track {
    let spec: OutputSpec
    let wavWriter: UnsafeMutablePointer<drwav>
    var hasSignal: Bool = false
}

// MARK: - Discovery

public func wavBitDepth(in dir: URL) -> UInt32? {
    guard let first = findWavTakes(in: dir).first else { return nil }
    let wav = UnsafeMutablePointer<drwav>.allocate(capacity: 1)
    defer { wav.deallocate() }
    guard first.path.withCString({ drwav_init_file(wav, $0, nil) }) == 1 else { return nil }
    let bits = UInt32(wav.pointee.bitsPerSample)
    drwav_uninit(wav)
    return bits
}

// MARK: - Splitter
// swiftlint:disable cyclomatic_complexity

/// Splits a multichannel WAV session into mono (and optionally stereo) WAV files.
/// Audio bytes are copied verbatim — no format conversion, no precision loss.
@discardableResult
public func splitSession(
    sessionDir: URL,
    outputDir: URL,
    prefix: String? = nil,
    stereoPairs: [StereoPair] = [],
    channelNames: [Int: String] = [:],
    useShortFilenames: Bool = false,
    progress: ProgressCallback? = nil
) throws -> SplitResult {
    let wavFiles = findWavTakes(in: sessionDir)
    guard !wavFiles.isEmpty else { throw SplitError.noWavFiles }

    // Read source format from first file
    let firstWav = UnsafeMutablePointer<drwav>.allocate(capacity: 1)
    guard wavFiles[0].path.withCString({ drwav_init_file(firstWav, $0, nil) }) == 1 else {
        firstWav.deallocate()
        throw SplitError.cannotOpenInput(wavFiles[0].lastPathComponent)
    }
    let numChannels  = Int(firstWav.pointee.channels)
    let sampleRate   = Double(firstWav.pointee.sampleRate)
    let sourceBits   = UInt32(firstWav.pointee.bitsPerSample)
    let formatTag    = firstWav.pointee.translatedFormatTag  // 1=PCM, 3=IEEE_FLOAT
    drwav_uninit(firstWav)
    firstWav.deallocate()

    let bytesPerSample = Int(sourceBits) / 8
    let frameStride    = numChannels * bytesPerSample

    // Validate stereo pairs
    let (activePairs, pairedChannels) = validateStereoPairs(stereoPairs, channelCount: numChannels)
    let stereoCount = activePairs.count
    let monoCount   = numChannels - pairedChannels.count

    let fmtLabel = formatTag == 3 ? "float" : "int"
    print("Source: \(numChannels) ch, \(Int(sampleRate)) Hz, \(sourceBits)-bit \(fmtLabel)")
    if stereoCount > 0 {
        print("Output: \(monoCount) mono + \(stereoCount) stereo (same format, byte-exact copy)")
    } else {
        print("Output: \(monoCount) mono (same format, byte-exact copy)")
    }
    print()

    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let pfx = prefix ?? sessionDir.lastPathComponent + "_"

    // Build output specs (filenames + kinds) — platform-independent
    let specs = buildOutputSpecs(
        activePairs: activePairs,
        pairedChannels: pairedChannels,
        numChannels: numChannels,
        channelNames: channelNames,
        outputDir: outputDir,
        prefix: pfx,
        useShortFilenames: useShortFilenames
    )

    // Create output writer with same format as source
    func makeWriter(_ url: URL, channels: UInt32) throws -> UnsafeMutablePointer<drwav> {
        var fmt = drwav_data_format()
        fmt.container     = drwav_container_riff
        fmt.format        = UInt32(formatTag)
        fmt.channels      = channels
        fmt.sampleRate    = UInt32(sampleRate)
        fmt.bitsPerSample = sourceBits
        let writer = UnsafeMutablePointer<drwav>.allocate(capacity: 1)
        guard url.path.withCString({ drwav_init_file_write(writer, $0, &fmt, nil) }) == 1 else {
            writer.deallocate()
            throw SplitError.cannotCreateOutput(url.lastPathComponent)
        }
        return writer
    }

    var tracks: [Track] = []
    do {
        for spec in specs {
            let channels: UInt32
            switch spec.kind {
            case .stereo: channels = 2
            case .mono:   channels = 1
            }
            let writer = try makeWriter(spec.url, channels: channels)
            tracks.append(Track(spec: spec, wavWriter: writer))
        }
    } catch {
        tracks.forEach { drwav_uninit($0.wavWriter); $0.wavWriter.deallocate() }
        throw error
    }

    // Allocate raw byte buffers
    let blockFrames = 4096
    let readBytes   = blockFrames * frameStride
    let rawIn       = UnsafeMutablePointer<UInt8>.allocate(capacity: readBytes)
    let monoOut     = UnsafeMutablePointer<UInt8>.allocate(capacity: blockFrames * bytesPerSample)
    let stereoOut   = UnsafeMutablePointer<UInt8>.allocate(capacity: blockFrames * bytesPerSample * 2)
    defer {
        rawIn.deallocate()
        monoOut.deallocate()
        stereoOut.deallocate()
    }

    var totalFramesWritten: UInt64 = 0

    for (takeIdx, wavURL) in wavFiles.enumerated() {
        let takeWav = UnsafeMutablePointer<drwav>.allocate(capacity: 1)
        guard wavURL.path.withCString({ drwav_init_file(takeWav, $0, nil) }) == 1 else {
            takeWav.deallocate()
            tracks.forEach { drwav_uninit($0.wavWriter); $0.wavWriter.deallocate() }
            throw SplitError.cannotOpenInput(wavURL.lastPathComponent)
        }
        guard Int(takeWav.pointee.channels) == numChannels else {
            drwav_uninit(takeWav); takeWav.deallocate()
            tracks.forEach { drwav_uninit($0.wavWriter); $0.wavWriter.deallocate() }
            throw SplitError.channelMismatch(
                expected: numChannels, got: Int(takeWav.pointee.channels),
                file: wavURL.lastPathComponent
            )
        }

        print("  Take \(takeIdx + 1)/\(wavFiles.count): \(wavURL.lastPathComponent) ...", terminator: "")
        fflush(stdout)

        var framesInTake: UInt64 = 0
        while true {
            let bytesRead = drwav_read_raw(takeWav, Int(readBytes), rawIn)
            if bytesRead == 0 { break }
            let frames = Int(bytesRead) / frameStride

            for ti in 0 ..< tracks.count {
                switch tracks[ti].spec.kind {
                case .mono(let ch):
                    demuxMono(from: rawIn, to: monoOut, frames: frames,
                              numChannels: numChannels, ch: ch,
                              bytesPerSample: bytesPerSample,
                              hasSignal: &tracks[ti].hasSignal)
                    let byteCount = frames * bytesPerSample
                    guard drwav_write_raw(tracks[ti].wavWriter, byteCount, monoOut) == byteCount else {
                        drwav_uninit(takeWav); takeWav.deallocate()
                        tracks.forEach { drwav_uninit($0.wavWriter); $0.wavWriter.deallocate() }
                        throw SplitError.writeError(0)
                    }

                case .stereo(let left, let right):
                    demuxStereo(from: rawIn, to: stereoOut, frames: frames,
                                numChannels: numChannels, left: left, right: right,
                                bytesPerSample: bytesPerSample,
                                hasSignal: &tracks[ti].hasSignal)
                    let byteCount = frames * bytesPerSample * 2
                    guard drwav_write_raw(tracks[ti].wavWriter, byteCount, stereoOut) == byteCount else {
                        drwav_uninit(takeWav); takeWav.deallocate()
                        tracks.forEach { drwav_uninit($0.wavWriter); $0.wavWriter.deallocate() }
                        throw SplitError.writeError(0)
                    }
                }
            }

            framesInTake += UInt64(frames)
            progress?(takeIdx + 1, wavFiles.count, framesInTake)
        }

        drwav_uninit(takeWav)
        takeWav.deallocate()
        totalFramesWritten += framesInTake
        print(" \(framesInTake) frames (\(formatTime(Double(framesInTake) / sampleRate)))")
    }

    for track in tracks {
        drwav_uninit(track.wavWriter)
        track.wavWriter.deallocate()
    }

    return collectSplitResult(
        specs: tracks.map(\.spec),
        hasSignal: tracks.map(\.hasSignal),
        totalFramesWritten: totalFramesWritten,
        sampleRate: sampleRate
    )
}
// swiftlint:enable cyclomatic_complexity
