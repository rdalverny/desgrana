// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Splitter
//
// Single cross-platform implementation built on WAVReader (input) and WAVWriter (output).
// Audio bytes are copied verbatim, no format conversion.

private struct Track {
    let spec: OutputSpec
    let writer: WAVWriter
    var hasSignal: Bool = false
}

private func openReader(_ url: URL) throws -> WAVReader {
    do {
        return try WAVReader(url: url)
    } catch let error as WAVReaderError {
        throw SplitError.cannotOpenInput("\(url.lastPathComponent): \(error)")
    }
}

// swiftlint:disable function_body_length cyclomatic_complexity
/// Splits a multichannel WAV session into mono (and optionally stereo) WAV files.
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
    let wavFiles = takes ?? findWavTakes(in: sessionDir)
    guard !wavFiles.isEmpty else { throw SplitError.noWavFiles }

    // Source format and provenance bext from the first take, in one open.
    let firstReader = try openReader(wavFiles[0])
    let numChannels  = firstReader.format.channels
    let sampleRate   = Double(firstReader.format.sampleRate)
    let sourceBits   = firstReader.format.bitsPerSample
    let isFloat      = firstReader.format.isFloat
    let sourceBext   = parseSourceBext(firstReader.metadataChunk("bext"))
    firstReader.close()

    let bytesPerSample = sourceBits / 8
    let frameStride    = numChannels * bytesPerSample

    let (activePairs, pairedChannels) = validateStereoPairs(stereoPairs, channelCount: numChannels)
    let stereoCount = activePairs.count
    let monoCount   = numChannels - pairedChannels.count

    print("Source: \(numChannels) ch, \(Int(sampleRate)) Hz, \(sourceBits)-bit \(isFloat ? "float" : "int")")
    if stereoCount > 0 {
        print("Output: \(monoCount) mono + \(stereoCount) stereo (same format, byte-exact copy)")
    } else {
        print("Output: \(monoCount) mono (same format, byte-exact copy)")
    }
    print()

    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let pfx = prefix ?? sessionDir.lastPathComponent + "_"

    let specs = buildOutputSpecs(
        activePairs: activePairs, pairedChannels: pairedChannels, numChannels: numChannels,
        channelNames: channelNames, outputDir: outputDir, prefix: pfx, useShortFilenames: useShortFilenames
    )

    // Metadata (bext/iXML/cue) embedded before `data` at file creation.
    let meta = outputMetadata(for: specs, sourceBext: sourceBext,
                              sampleRate: Int(sampleRate), markers: markers)

    // Create outputs (WAVWriter closes its handle on deinit, so writers made so far
    // are cleaned up if a later one throws).
    var tracks: [Track] = []
    for (spec, chunks) in zip(specs, meta) {
        let writer = try WAVWriter(
            url: spec.url,
            format: WAVFormat(channels: spec.kind.channelCount, sampleRate: Int(sampleRate),
                              bitsPerSample: sourceBits, isFloat: isFloat),
            metadata: chunks
        )
        tracks.append(Track(spec: spec, writer: writer))
    }

    let blockFrames = 4096
    let readBytes   = blockFrames * frameStride
    let rawIn       = UnsafeMutablePointer<UInt8>.allocate(capacity: readBytes)
    let monoOut     = UnsafeMutablePointer<UInt8>.allocate(capacity: blockFrames * bytesPerSample)
    let stereoOut   = UnsafeMutablePointer<UInt8>.allocate(capacity: blockFrames * bytesPerSample * 2)
    defer {
        rawIn.deallocate(); monoOut.deallocate(); stereoOut.deallocate()
    }

    var totalFramesWritten: UInt64 = 0

    for (takeIdx, wavURL) in wavFiles.enumerated() {
        let reader = try openReader(wavURL)
        defer { reader.close() }
        guard reader.format.channels == numChannels else {
            throw SplitError.channelMismatch(expected: numChannels, got: reader.format.channels,
                                             file: wavURL.lastPathComponent)
        }

        print("  Take \(takeIdx + 1)/\(wavFiles.count): \(wavURL.lastPathComponent) ...", terminator: "")
        fflush(stdout)

        var framesInTake: UInt64 = 0
        while true {
            let bytesRead = try reader.read(into: UnsafeMutableRawBufferPointer(start: rawIn, count: readBytes))
            if bytesRead == 0 { break }
            let frames = bytesRead / frameStride

            for ti in 0 ..< tracks.count {
                let byteCount: Int
                let out: UnsafeMutablePointer<UInt8>
                switch tracks[ti].spec.kind {
                case .mono(let ch):
                    demuxMono(from: rawIn, to: monoOut, frames: frames, numChannels: numChannels,
                              ch: ch, bytesPerSample: bytesPerSample, isFloat: isFloat,
                              hasSignal: &tracks[ti].hasSignal)
                    out = monoOut; byteCount = frames * bytesPerSample
                case .stereo(let left, let right):
                    demuxStereo(from: rawIn, to: stereoOut, frames: frames, numChannels: numChannels,
                                left: left, right: right, bytesPerSample: bytesPerSample, isFloat: isFloat,
                                hasSignal: &tracks[ti].hasSignal)
                    out = stereoOut; byteCount = frames * bytesPerSample * 2
                }
                do {
                    try tracks[ti].writer.append(UnsafeRawBufferPointer(start: out, count: byteCount))
                } catch {
                    throw SplitError.writeError(0)
                }
            }

            framesInTake += UInt64(frames)
            progress?(takeIdx + 1, wavFiles.count, framesInTake)
        }

        totalFramesWritten += framesInTake
        print(" \(framesInTake) frames (\(formatTime(Double(framesInTake) / sampleRate)))")
    }

    for track in tracks { try track.writer.finalize() }

    return collectSplitResult(
        specs: tracks.map(\.spec), hasSignal: tracks.map(\.hasSignal),
        totalFramesWritten: totalFramesWritten, sampleRate: sampleRate
    )
}
// swiftlint:enable function_body_length cyclomatic_complexity
