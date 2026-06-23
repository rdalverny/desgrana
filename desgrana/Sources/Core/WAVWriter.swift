// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Streaming RIFF/RF64 WAV writer
//
// Writes a WAV output ourselves (instead of delegating the header to dr_wav /
// ExtAudioFile) so that metadata chunks (bext, iXML, cue) land BEFORE the `data`
// chunk, with zero post-hoc rewrite. The audio payload is appended verbatim — this
// writer never converts samples, it only frames raw little-endian bytes.
//
// RF64 (>4 GB) is handled with the standard reservation technique: a 28-byte `JUNK`
// chunk is written up front where a `ds64` would go. At finalize, if the file stays
// under 4 GB it is left as `JUNK` (plain RIFF, ignored by every reader); otherwise it
// is rewritten in place as `ds64` and the RIFF/`data` size fields switch to the
// 0xFFFF_FFFF sentinel. So the final size class is decided only once, at close.

public struct WAVFormat {
    public let channels: Int
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let isFloat: Bool
    public init(channels: Int, sampleRate: Int, bitsPerSample: Int, isFloat: Bool) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.isFloat = isFloat
    }
    var blockAlign: Int { channels * bitsPerSample / 8 }
}

public enum WAVWriterError: Error {
    case cannotCreate(URL)
}

public final class WAVWriter {
    private let fh: FileHandle
    private let format: WAVFormat

    // File offsets of the fields patched at finalize (recorded while building the header).
    private let ds64HeaderOffset: UInt64   // the `JUNK`/`ds64` chunk id
    private let ds64BodyOffset: UInt64     // start of the 28-byte ds64 body
    private let factSampleOffset: UInt64?  // fact sampleCount (non-PCM only)
    private let dataSizeOffset: UInt64     // the `data` chunk's 32-bit size field

    private var dataBytes: UInt64 = 0
    private var finalized = false

    /// Largest plain-RIFF size before switching to RF64. Overridable in tests to
    /// exercise the RF64 path without writing 4 GB.
    var rf64Threshold: UInt64 = 0xFFFF_FFFE

    /// Creates the WAV at `url` and writes its header: RIFF + ds64 reservation + fmt
    /// (+ fact when float) + the given metadata chunks + an empty `data` header.
    /// `metadata` chunks are written verbatim, in order, before `data`.
    public init(url: URL, format: WAVFormat, metadata: [(id: String, payload: Data)] = []) throws {
        self.format = format

        var h = Data()
        func id(_ s: String) { h.append(contentsOf: s.utf8) }

        id("RIFF"); h.appendLE(UInt32(0)); id("WAVE")    // RIFF size patched at finalize

        // ds64 reservation, parked as JUNK until/unless the file grows past 4 GB.
        ds64HeaderOffset = UInt64(h.count)
        id("JUNK"); h.appendLE(UInt32(28))
        ds64BodyOffset = UInt64(h.count)
        h.append(Data(count: 28))                        // riffSize(8) dataSize(8) sampleCount(8) table(4)

        id("fmt "); h.appendLE(UInt32(16))
        h.appendLE(UInt16(format.isFloat ? 3 : 1))       // 1=PCM, 3=IEEE float
        h.appendLE(UInt16(format.channels))
        h.appendLE(UInt32(format.sampleRate))
        h.appendLE(UInt32(format.sampleRate * format.blockAlign))
        h.appendLE(UInt16(format.blockAlign))
        h.appendLE(UInt16(format.bitsPerSample))

        if format.isFloat {                              // non-PCM should carry a fact chunk
            id("fact"); h.appendLE(UInt32(4))
            factSampleOffset = UInt64(h.count)
            h.appendLE(UInt32(0))                        // sampleCount patched at finalize
        } else {
            factSampleOffset = nil
        }

        for (cid, payload) in metadata {
            id(cid); h.appendLE(UInt32(payload.count)); h.append(payload)
            if payload.count % 2 == 1 { h.append(0) }    // RIFF pad to even
        }

        id("data")
        dataSizeOffset = UInt64(h.count)
        h.appendLE(UInt32(0))                            // data size patched at finalize

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw WAVWriterError.cannotCreate(url)
        }
        fh = handle
        try fh.write(contentsOf: h)
    }

    /// Appends raw sample bytes to the `data` chunk.
    public func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try fh.write(contentsOf: data)
        dataBytes += UInt64(data.count)
    }

    /// Appends raw sample bytes from a buffer without copying (hot path for the splitters).
    public func append(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        try fh.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                                      count: bytes.count, deallocator: .none))
        dataBytes += UInt64(bytes.count)
    }

    /// Pads the `data` chunk to an even length, patches every size field, upgrades the
    /// JUNK reservation to `ds64` if the file exceeds 4 GB, and closes the file.
    public func finalize() throws {
        guard !finalized else { return }
        finalized = true

        if dataBytes % 2 == 1 { try fh.write(contentsOf: Data([0])) }   // RIFF pad byte
        let pad: UInt64 = dataBytes % 2
        let fileSize = dataSizeOffset + 4 + dataBytes + pad
        let riffSize = fileSize - 8
        let frameCount = format.blockAlign > 0 ? dataBytes / UInt64(format.blockAlign) : 0

        if riffSize > rf64Threshold || dataBytes > rf64Threshold {
            try fh.patch(at: 0, Data("RF64".utf8))
            try fh.patch(at: 4, Data(le: UInt32(0xFFFF_FFFF)))
            try fh.patch(at: ds64HeaderOffset, Data("ds64".utf8))
            try fh.patch(at: ds64BodyOffset,
                         Data(le: riffSize) + Data(le: dataBytes) + Data(le: frameCount) + Data(le: UInt32(0)))
            try fh.patch(at: dataSizeOffset, Data(le: UInt32(0xFFFF_FFFF)))
        } else {
            try fh.patch(at: 4, Data(le: UInt32(riffSize)))
            try fh.patch(at: dataSizeOffset, Data(le: UInt32(dataBytes)))
        }
        if let f = factSampleOffset {
            try fh.patch(at: f, Data(le: frameCount > 0xFFFF_FFFE ? 0xFFFF_FFFF : UInt32(frameCount)))
        }
        try fh.close()
    }
}
