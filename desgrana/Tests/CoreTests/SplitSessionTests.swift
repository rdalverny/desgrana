// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class SplitSessionTests: XCTestCase {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 2-channel 16-bit PCM WAV with non-silent samples.
    private func writeStereoWAV(to url: URL) throws {
        let format = WAVFormat(channels: 2, sampleRate: 48_000, bitsPerSample: 16, isFloat: false)
        let writer = try WAVWriter(url: url, format: format)
        let samples: [Int16] = Array(repeating: [1000, -1000], count: 64).flatMap { $0 }
        try writer.append(samples.withUnsafeBytes { Data($0) })
        try writer.finalize()
    }

    // Output dir == input dir, short names, channel 1 named like the input:
    // the output "Live.wav" would truncate the input "Live.wav".
    func testOutputCollidingWithInputLeavesInputIntact() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("Live.wav")
        try writeStereoWAV(to: input)
        let original = try Data(contentsOf: input)

        XCTAssertThrowsError(try splitSession(
            sessionDir: dir, outputDir: dir,
            channelNames: [1: "Live"], useShortFilenames: true, takes: [input]
        ))

        XCTAssertEqual(try Data(contentsOf: input), original)
    }
}
