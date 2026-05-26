// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class DAWExportTests: XCTestCase {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - RPP

    func testRPPContainsTrackNames() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [
            (dir.appendingPathComponent("Kick.wav"),  1),
            (dir.appendingPathComponent("Snare.wav"), 1)
        ]
        let url = try generateRPP(wavs: wavs, duration: 10, sampleRate: 48000,
                                  markers: [], outputDir: dir)
        let content = try String(contentsOf: url)

        XCTAssertTrue(content.contains("NAME \"Kick\""))
        XCTAssertTrue(content.contains("NAME \"Snare\""))
    }

    func testRPPMarkerTime() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [(dir.appendingPathComponent("BD.wav"), 1)]
        let url = try generateRPP(wavs: wavs, duration: 10, sampleRate: 48000,
                                  markers: [(3.5, "Verse")], outputDir: dir)
        let content = try String(contentsOf: url)

        XCTAssertTrue(content.contains("MARKER 1 3.500000 \"Verse\""))
    }

    func testRPPFilenameMatchesOutputDir() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try generateRPP(wavs: [], duration: 0, sampleRate: 48000,
                                  markers: [], outputDir: dir)
        XCTAssertEqual(url.pathExtension, "rpp")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, dir.lastPathComponent)
    }

    // MARK: - Ardour

    func testArdourContainsTrackNames() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [
            (dir.appendingPathComponent("Kick.wav"),  1),
            (dir.appendingPathComponent("OH.wav"),    2)
        ]
        let url = try generateArdourSession(wavs: wavs, duration: 10, sampleRate: 48000,
                                            markers: [], outputDir: dir)
        let content = try String(contentsOf: url)

        XCTAssertTrue(content.contains("name=\"Kick\""))
        XCTAssertTrue(content.contains("name=\"OH\""))
    }

    func testArdourStereoChannelCount() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [
            (dir.appendingPathComponent("Mono.wav"),   1),
            (dir.appendingPathComponent("Stereo.wav"), 2)
        ]
        let url = try generateArdourSession(wavs: wavs, duration: 10, sampleRate: 48000,
                                            markers: [], outputDir: dir)
        let content = try String(contentsOf: url)

        // Both Route and Diskstream carry the channel count.
        let mono   = content.components(separatedBy: "channels=\"1\"").count - 1
        let stereo = content.components(separatedBy: "channels=\"2\"").count - 1
        XCTAssertEqual(mono,   2, "expected 2 occurrences of channels=\"1\" (Route + Diskstream)")
        XCTAssertEqual(stereo, 2, "expected 2 occurrences of channels=\"2\" (Route + Diskstream)")
    }

    func testArdourMarkerSample() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [(dir.appendingPathComponent("BD.wav"), 1)]
        let url = try generateArdourSession(wavs: wavs, duration: 10, sampleRate: 48000,
                                            markers: [(2.0, "Drop")], outputDir: dir)
        let content = try String(contentsOf: url)

        // 2.0s × 48000 = 96000 samples
        XCTAssertTrue(content.contains("name=\"Drop\""))
        XCTAssertTrue(content.contains("start=\"96000\""))
        XCTAssertTrue(content.contains("flags=\"IsMark\""))
    }

    func testArdourXMLEscaping() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [
            (dir.appendingPathComponent("Bass&Guitar.wav"), 1)
        ]
        let url = try generateArdourSession(wavs: wavs, duration: 5, sampleRate: 48000,
                                            markers: [], outputDir: dir)
        let content = try String(contentsOf: url)

        XCTAssertTrue(content.contains("Bass&amp;Guitar"))
        XCTAssertFalse(content.contains("Bass&Guitar"))
    }
}
