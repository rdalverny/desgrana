// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import CWav
import DesgranaCore

// MARK: - Internal track representation

private struct Track {
    let spec: OutputSpec
    let writer: WAVWriter
    var hasSignal: Bool = false
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
    takes: [URL]? = nil,
    markers: [UInt32] = [],
    progress: ProgressCallback? = nil
) throws -> SplitResult {
    // Use the explicitly resolved takes if provided, else fall back to hex-named discovery.
    let wavFiles = takes ?? findWavTakes(in: sessionDir)
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
    guard bytesPerSample > 0 else {
        throw SplitError.cannotOpenInput("\(wavFiles[0].lastPathComponent) (unsupported bit depth: \(sourceBits))")
    }
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

    // Metadata (bext/iXML/cue) embedded before `data` at file creation.
    let meta = outputMetadata(for: specs, source: wavFiles.first,
                              sampleRate: Int(sampleRate), markers: markers)

    // Create output files with the same format as the source (WAVWriter closes its
    // file handle on deinit, so writers created so far are cleaned up if one throws).
    var tracks: [Track] = []
    for (spec, chunks) in zip(specs, meta) {
        let channels = spec.kind.isStereo ? 2 : 1
        let writer = try WAVWriter(
            url: spec.url,
            format: WAVFormat(channels: channels, sampleRate: Int(sampleRate),
                              bitsPerSample: Int(sourceBits), isFloat: formatTag == 3),
            metadata: chunks
        )
        tracks.append(Track(spec: spec, writer: writer))
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
            throw SplitError.cannotOpenInput(wavURL.lastPathComponent)
        }
        guard Int(takeWav.pointee.channels) == numChannels else {
            drwav_uninit(takeWav); takeWav.deallocate()
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
                              bytesPerSample: bytesPerSample, isFloat: formatTag == 3,
                              hasSignal: &tracks[ti].hasSignal)
                    let byteCount = frames * bytesPerSample
                    do {
                        try tracks[ti].writer.append(UnsafeRawBufferPointer(start: monoOut, count: byteCount))
                    } catch {
                        drwav_uninit(takeWav); takeWav.deallocate()
                        throw SplitError.writeError(0)
                    }

                case .stereo(let left, let right):
                    demuxStereo(from: rawIn, to: stereoOut, frames: frames,
                                numChannels: numChannels, left: left, right: right,
                                bytesPerSample: bytesPerSample, isFloat: formatTag == 3,
                                hasSignal: &tracks[ti].hasSignal)
                    let byteCount = frames * bytesPerSample * 2
                    do {
                        try tracks[ti].writer.append(UnsafeRawBufferPointer(start: stereoOut, count: byteCount))
                    } catch {
                        drwav_uninit(takeWav); takeWav.deallocate()
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

    for track in tracks { try track.writer.finalize() }

    return collectSplitResult(
        specs: tracks.map(\.spec),
        hasSignal: tracks.map(\.hasSignal),
        totalFramesWritten: totalFramesWritten,
        sampleRate: sampleRate
    )
}
// swiftlint:enable cyclomatic_complexity
