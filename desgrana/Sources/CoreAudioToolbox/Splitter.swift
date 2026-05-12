// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import AudioToolbox
import Foundation
import DesgranaCore

// MARK: - Internal track representation

private enum TrackKind {
    case mono(ch: Int)                 // 0-indexed
    case stereo(left: Int, right: Int) // 0-indexed
}

private struct Track {
    let kind: TrackKind
    let fileRef: ExtAudioFileRef
    let url: URL
    var hasSignal: Bool = false
}

// MARK: - Discovery

/// Returns the bit depth of the first WAV take found in `dir`, or nil if unreadable.
public func wavBitDepth(in dir: URL) -> UInt32? {
    guard let first = findWavTakes(in: dir).first else { return nil }
    var file: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(first as CFURL, &file) == noErr, let f = file else { return nil }
    defer { ExtAudioFileDispose(f) }
    var fmt = AudioStreamBasicDescription()
    var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &fmt) == noErr else { return nil }
    return fmt.mBitsPerChannel
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
    var inputFile: ExtAudioFileRef?
    var status = ExtAudioFileOpenURL(wavFiles[0] as CFURL, &inputFile)
    guard status == noErr, let firstFile = inputFile else {
        throw SplitError.cannotOpenInput("\(wavFiles[0].lastPathComponent) (OSStatus \(status))")
    }
    var srcFmt = AudioStreamBasicDescription()
    var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    status = ExtAudioFileGetProperty(firstFile, kExtAudioFileProperty_FileDataFormat, &propSize, &srcFmt)
    guard status == noErr else {
        ExtAudioFileDispose(firstFile)
        throw SplitError.cannotGetFormat(status)
    }
    ExtAudioFileDispose(firstFile)

    let numChannels  = Int(srcFmt.mChannelsPerFrame)
    let sampleRate   = srcFmt.mSampleRate
    let bytesPerSample = Int(srcFmt.mBitsPerChannel) / 8   // bytes per sample per channel
    let frameStride  = numChannels * bytesPerSample         // bytes per interleaved frame

    // Derive mono / stereo output formats from source (just change channel count)
    var monoFmt   = srcFmt
    monoFmt.mChannelsPerFrame = 1
    monoFmt.mBytesPerFrame    = UInt32(bytesPerSample)
    monoFmt.mBytesPerPacket   = UInt32(bytesPerSample)

    var stereoFmt = srcFmt
    stereoFmt.mChannelsPerFrame = 2
    stereoFmt.mBytesPerFrame    = UInt32(bytesPerSample * 2)
    stereoFmt.mBytesPerPacket   = UInt32(bytesPerSample * 2)

    // Validate stereo pairs
    let (activePairs, pairedChannels) = validateStereoPairs(stereoPairs, channelCount: numChannels)
    let stereoCount    = activePairs.count
    let monoCount      = numChannels - pairedChannels.count

    let isFloat = srcFmt.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let fmtLabel = isFloat ? "float" : "int"
    print("Source: \(numChannels) ch, \(Int(sampleRate)) Hz, \(srcFmt.mBitsPerChannel)-bit \(fmtLabel)")
    if stereoCount > 0 {
        print("Output: \(monoCount) mono + \(stereoCount) stereo (same format, byte-exact copy)")
    } else {
        print("Output: \(monoCount) mono (same format, byte-exact copy)")
    }
    print()

    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let pfx = prefix ?? sessionDir.lastPathComponent + "_"

    // Create output files
    func makeOutputFile(_ url: URL, fmt: inout AudioStreamBasicDescription) throws -> ExtAudioFileRef {
        var outFile: ExtAudioFileRef?
        var s = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileWAVEType, &fmt, nil,
            AudioFileFlags.eraseFile.rawValue, &outFile
        )
        guard s == noErr, let f = outFile else {
            throw SplitError.cannotCreateOutput("\(url.lastPathComponent) (OSStatus \(s))")
        }
        // Client format = file format: no conversion, raw bytes passed through
        s = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &fmt)
        guard s == noErr else {
            ExtAudioFileDispose(f)
            throw SplitError.cannotSetClientFormat(s)
        }
        return f
    }

    var tracks: [Track] = []
    do {
        for pair in activePairs {
            let suffix = channelNameSuffix(for: [pair.left, pair.right], names: channelNames)
            let filename = useShortFilenames
                ? (suffix.isEmpty ? String(format: "ch%02d-%02d.wav", pair.left, pair.right) : "\(suffix.dropFirst()).wav")
                : String(format: "%@ch%02d-%02d\(suffix).wav", pfx, pair.left, pair.right)
            let url = outputDir.appendingPathComponent(filename)
            let f = try makeOutputFile(url, fmt: &stereoFmt)
            // pairs are 1-indexed; tracks are 0-indexed
            tracks.append(Track(kind: .stereo(left: pair.left - 1, right: pair.right - 1), fileRef: f, url: url))
        }
        for ch in 0 ..< numChannels where !pairedChannels.contains(ch + 1) {
            let suffix = channelNameSuffix(for: [ch + 1], names: channelNames)
            let filename = useShortFilenames
                ? (suffix.isEmpty ? String(format: "ch%02d.wav", ch + 1) : "\(suffix.dropFirst()).wav")
                : String(format: "%@ch%02d\(suffix).wav", pfx, ch + 1)
            let url = outputDir.appendingPathComponent(filename)
            let f = try makeOutputFile(url, fmt: &monoFmt)
            tracks.append(Track(kind: .mono(ch: ch), fileRef: f, url: url))
        }
    } catch {
        tracks.forEach { ExtAudioFileDispose($0.fileRef) }
        throw error
    }

    // Allocate raw byte buffers
    let blockFrames = 4096
    let readBytes   = blockFrames * frameStride
    // monoOut and stereoOut are reused for every track per block; each track writes immediately before the next reuses the buffer.
    let rawIn       = UnsafeMutablePointer<UInt8>.allocate(capacity: readBytes)
    let monoOut     = UnsafeMutablePointer<UInt8>.allocate(capacity: blockFrames * bytesPerSample)
    let stereoOut   = UnsafeMutablePointer<UInt8>.allocate(capacity: blockFrames * bytesPerSample * 2)
    defer {
        rawIn.deallocate()
        monoOut.deallocate()
        stereoOut.deallocate()
    }

    // Set source client format = file format on each take file (done per-take below)
    var totalFramesWritten: UInt64 = 0

    for (takeIdx, wavURL) in wavFiles.enumerated() {
        var takeFile: ExtAudioFileRef?
        status = ExtAudioFileOpenURL(wavURL as CFURL, &takeFile)
        guard status == noErr, let tf = takeFile else {
            tracks.forEach { ExtAudioFileDispose($0.fileRef) }
            throw SplitError.cannotOpenInput("\(wavURL.lastPathComponent) (OSStatus \(status))")
        }

        // Verify channel count matches
        var takeFmt = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(tf, kExtAudioFileProperty_FileDataFormat, &sz, &takeFmt)
        guard Int(takeFmt.mChannelsPerFrame) == numChannels else {
            ExtAudioFileDispose(tf)
            tracks.forEach { ExtAudioFileDispose($0.fileRef) }
            throw SplitError.channelMismatch(
                expected: numChannels, got: Int(takeFmt.mChannelsPerFrame),
                file: wavURL.lastPathComponent
            )
        }

        // Client format = file format: read raw bytes, no conversion
        var clientFmt = takeFmt
        status = ExtAudioFileSetProperty(tf, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFmt)
        guard status == noErr else {
            ExtAudioFileDispose(tf)
            tracks.forEach { ExtAudioFileDispose($0.fileRef) }
            throw SplitError.cannotSetClientFormat(status)
        }

        print("  Take \(takeIdx + 1)/\(wavFiles.count): \(wavURL.lastPathComponent) ...", terminator: "")
        fflush(stdout)

        var framesInTake: UInt64 = 0

        while true {
            var framesToRead = UInt32(blockFrames)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(numChannels),
                    mDataByteSize: UInt32(readBytes),
                    mData: rawIn
                )
            )
            status = ExtAudioFileRead(tf, &framesToRead, &bufferList)
            guard status == noErr else {
                ExtAudioFileDispose(tf)
                tracks.forEach { ExtAudioFileDispose($0.fileRef) }
                throw SplitError.readError(status)
            }
            if framesToRead == 0 { break }
            let frames = Int(framesToRead)

            for ti in 0 ..< tracks.count {
                switch tracks[ti].kind {
                case .mono(let ch):
                    demuxMono(from: rawIn, to: monoOut, frames: frames,
                              numChannels: numChannels, ch: ch,
                              bytesPerSample: bytesPerSample,
                              hasSignal: &tracks[ti].hasSignal)
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(frames * bytesPerSample),
                            mData: monoOut
                        )
                    )
                    status = ExtAudioFileWrite(tracks[ti].fileRef, UInt32(frames), &list)
                    guard status == noErr else {
                        ExtAudioFileDispose(tf)
                        tracks.forEach { ExtAudioFileDispose($0.fileRef) }
                        throw SplitError.writeError(status)
                    }

                case .stereo(let left, let right):
                    demuxStereo(from: rawIn, to: stereoOut, frames: frames,
                                numChannels: numChannels, left: left, right: right,
                                bytesPerSample: bytesPerSample,
                                hasSignal: &tracks[ti].hasSignal)
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(frames * bytesPerSample * 2),
                            mData: stereoOut
                        )
                    )
                    status = ExtAudioFileWrite(tracks[ti].fileRef, UInt32(frames), &list)
                    guard status == noErr else {
                        ExtAudioFileDispose(tf)
                        tracks.forEach { ExtAudioFileDispose($0.fileRef) }
                        throw SplitError.writeError(status)
                    }
                }
            }

            framesInTake += UInt64(frames)
            progress?(takeIdx + 1, wavFiles.count, framesInTake)
        }

        ExtAudioFileDispose(tf)
        totalFramesWritten += framesInTake
        print(" \(framesInTake) frames (\(formatTime(Double(framesInTake) / sampleRate)))")
    }

    for track in tracks { ExtAudioFileDispose(track.fileRef) }

    // Remove silent tracks
    var keptURLs: [URL] = []
    var silentCount = 0
    var keptMonoCount = 0, keptStereoCount = 0
    for track in tracks {
        if !track.hasSignal {
            try? FileManager.default.removeItem(at: track.url)
            silentCount += 1
        } else {
            keptURLs.append(track.url)
            switch track.kind {
            case .mono:   keptMonoCount += 1
            case .stereo: keptStereoCount += 1
            }
        }
    }

    return SplitResult(urls: keptURLs, keptMono: keptMonoCount, keptStereo: keptStereoCount,
                       silentSkipped: silentCount, totalFrames: totalFramesWritten, sampleRate: sampleRate)
}
// swiftlint:enable cyclomatic_complexity
