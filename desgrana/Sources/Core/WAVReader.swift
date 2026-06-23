// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Streaming RIFF/RF64 WAV reader
//
// The pure-Swift counterpart to WAVWriter. Parses the header for format and the `data`
// chunk location, then streams raw interleaved sample bytes in frame-aligned blocks.
// It never decodes or converts: it hands back the bytes exactly as stored.
//
// Scope (v1): little-endian PCM / IEEE-float, RIFF and RF64, including
// WAVE_FORMAT_EXTENSIBLE. Big-endian (RIFX/AIFF), Wave64 and compressed codecs are
// out of scope and rejected with `unsupportedFormat` / `notRIFF`. See docs/WAVREADER.md.

public enum WAVReaderError: Error, CustomStringConvertible {
    case cannotOpen(URL)
    case notRIFF                    // missing RIFF/RF64 + WAVE signature
    case missingFmtChunk
    case missingDataChunk
    case unsupportedFormat(String)  // compressed codec, odd bit depth, etc.
    case malformed(String)          // structurally broken header we don't tolerate

    public var description: String {
        switch self {
        case .cannotOpen(let u):       return "Cannot open WAV '\(u.lastPathComponent)'"
        case .notRIFF:                 return "Not a RIFF/RF64 WAVE file"
        case .missingFmtChunk:         return "WAV has no 'fmt ' chunk"
        case .missingDataChunk:        return "WAV has no 'data' chunk"
        case .unsupportedFormat(let s): return "Unsupported WAV format: \(s)"
        case .malformed(let s):        return "Malformed WAV: \(s)"
        }
    }
}

public final class WAVReader {
    /// Format parsed from the `fmt ` chunk.
    public let format: WAVFormat
    /// True `data` size in bytes after RF64 and truncation resolution. May be less than
    /// the header-declared size for a take cut at the 4 GB FAT32 limit.
    public let dataByteCount: UInt64
    /// Whole frames available.
    public var frameCount: UInt64 { format.blockAlign > 0 ? dataByteCount / UInt64(format.blockAlign) : 0 }

    /// Metadata chunks found before `data`, keyed by 4-char id. Collected during the same
    /// header walk so callers need not re-open the file. Pre-`data` only (bext/iXML/cue
    /// conventionally precede `data`).
    public let metadata: [String: Data]

    /// Convenience lookup into `metadata` (e.g. `metadataChunk("bext")`).
    public func metadataChunk(_ id: String) -> Data? { metadata[id] }

    /// Small pre-`data` chunk ids worth keeping; others are skipped without reading payload.
    private static let metadataIDs: Set<String> = ["bext", "iXML", "cue ", "smpl", "fact"]
    /// Don't buffer a metadata chunk larger than this (guards against a pathological size).
    private static let metadataCap: UInt64 = 4 << 20

    private let fh: FileHandle
    private var bytesRemaining: UInt64
    private var closed = false

    // swiftlint:disable:next cyclomatic_complexity
    public init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw WAVReaderError.cannotOpen(url)
        }

        func readBytes(_ n: Int) -> [UInt8]? {
            guard let d = try? handle.read(upToCount: n), d.count == n else { return nil }
            return [UInt8](d)
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        // Container header: RIFF/RF64 + WAVE.
        guard let head = readBytes(12) else { handle.closeQuietly(); throw WAVReaderError.notRIFF }
        let container = fourCC(head, 0)
        guard container == "RIFF" || container == "RF64", fourCC(head, 8) == "WAVE" else {
            handle.closeQuietly(); throw WAVReaderError.notRIFF
        }

        var parsedFormat: WAVFormat?
        var rf64DataSize: UInt64?       // authoritative `data` size from ds64 (RF64)
        var dataStart: UInt64?
        var dataDeclared: UInt64 = 0    // 32-bit `data` size as written (sentinel-aware below)
        var collected: [String: Data] = [:]

        var offset: UInt64 = 12
        chunks: while true {
            try? handle.seek(toOffset: offset)
            guard let hdr = readBytes(8) else { break }      // EOF: no more chunks
            let cid = fourCC(hdr, 0)
            let size = UInt64(leU32(hdr, 4))
            let payloadStart = offset + 8
            let pad = size & 1

            switch cid {
            case "data":
                dataStart = payloadStart
                dataDeclared = size
                break chunks                                  // v1 needs nothing past `data`

            case "fmt ":
                guard let body = readBytes(Int(size)), body.count >= 16 else {
                    handle.closeQuietly(); throw WAVReaderError.malformed("short fmt chunk")
                }
                parsedFormat = try Self.parseFormat(body)

            case "ds64":
                if let body = readBytes(Int(size)), body.count >= 16 {
                    rf64DataSize = leU64(body, 8)             // riffSize(8), dataSize(8), ...
                }

            default:
                if Self.metadataIDs.contains(cid), size <= Self.metadataCap,
                   let body = readBytes(Int(size)) {
                    collected[cid] = Data(body)
                }
            }

            offset = payloadStart + size + pad
        }

        guard let fmt = parsedFormat else { handle.closeQuietly(); throw WAVReaderError.missingFmtChunk }
        guard let start = dataStart else { handle.closeQuietly(); throw WAVReaderError.missingDataChunk }

        // Resolve the declared data size (RF64-aware). Truncation is tolerated at read
        // time (reads stop at EOF), so this stays the declared size, not a clamp: a take
        // cut at the 4 GB limit still reports its intended length for duration/probe.
        let available = fileSize > start ? fileSize - start : 0
        let resolved: UInt64
        if container == "RF64" || dataDeclared == 0xFFFF_FFFF {
            resolved = rf64DataSize ?? available             // RF64 sentinel -> ds64, else fill
        } else if dataDeclared == 0 {
            resolved = available                              // streamed/unknown -> fill
        } else {
            resolved = dataDeclared
        }

        self.fh = handle
        self.format = fmt
        self.dataByteCount = resolved
        self.bytesRemaining = resolved
        self.metadata = collected
        try? handle.seek(toOffset: start)
    }

    deinit { close() }

    /// Releases the file handle. Idempotent.
    public func close() {
        guard !closed else { return }
        closed = true
        try? fh.close()
    }

    /// Fills `buffer` with raw interleaved sample bytes, truncated to a whole number of
    /// frames and to the remaining `data` payload. Returns bytes written (0 at end).
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard !closed, let base = buffer.baseAddress else { return 0 }
        let blockAlign = UInt64(format.blockAlign)
        guard blockAlign > 0 else { return 0 }

        let fitsBuffer = UInt64(buffer.count) - UInt64(buffer.count) % blockAlign
        let want = min(fitsBuffer, bytesRemaining - bytesRemaining % blockAlign)
        guard want > 0 else { return 0 }

        var got = 0
        while UInt64(got) < want {
            guard let chunk = try fh.read(upToCount: Int(want) - got), !chunk.isEmpty else {
                break                                         // unexpected EOF past the clamp
            }
            chunk.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[got ..< got + chunk.count]))
            got += chunk.count
        }

        let aligned = got - got % Int(blockAlign)             // never return a partial frame
        bytesRemaining -= UInt64(aligned)
        return aligned
    }

    /// Convenience: reads up to `maxFrames` frames into a freshly allocated `Data`.
    public func read(maxFrames: Int) throws -> Data {
        var data = Data(count: max(maxFrames, 0) * format.blockAlign)
        let n = try data.withUnsafeMutableBytes { try read(into: $0) }
        data.removeSubrange(n ..< data.count)
        return data
    }

    // MARK: - fmt parsing

    /// Parses a `fmt ` body (16/18/40 bytes), resolving WAVE_FORMAT_EXTENSIBLE.
    private static func parseFormat(_ b: [UInt8]) throws -> WAVFormat {
        let formatTag = leU16(b, 0)
        let channels  = leU16(b, 2)
        let rate      = Int(leU32(b, 4))
        let bits      = leU16(b, 14)

        var effectiveTag = formatTag
        var validBits = bits
        var channelMask: UInt32 = 0

        if formatTag == 0xFFFE {                              // WAVE_FORMAT_EXTENSIBLE
            guard b.count >= 40 else { throw WAVReaderError.malformed("short EXTENSIBLE fmt") }
            validBits    = leU16(b, 18)
            channelMask  = leU32(b, 20)
            effectiveTag = leU16(b, 24)                       // first 2 bytes of the subFormat GUID
        }

        guard effectiveTag == 1 || effectiveTag == 3 else {
            throw WAVReaderError.unsupportedFormat("format tag \(effectiveTag) (not PCM or IEEE float)")
        }
        guard bits > 0, bits % 8 == 0 else {
            throw WAVReaderError.unsupportedFormat("bit depth \(bits)")
        }
        guard channels > 0 else { throw WAVReaderError.malformed("zero channels") }

        return WAVFormat(channels: channels, sampleRate: rate, bitsPerSample: bits,
                         isFloat: effectiveTag == 3,
                         validBitsPerSample: validBits, channelMask: channelMask)
    }
}

private extension FileHandle {
    func closeQuietly() { try? close() }
}
