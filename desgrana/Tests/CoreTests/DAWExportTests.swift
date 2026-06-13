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

    /// Writes a real, playable 16-bit PCM mono WAV (a sine tone) so the file can
    /// actually be opened and listened to in a DAW, unlike header-only test fixtures.
    private func writePlayableWAV(
        to url: URL, seconds: Double, frequency: Double, sampleRate: Double
    ) throws {
        let frames = Int(seconds * sampleRate)
        let dataSize = frames * 2                      // 16-bit mono
        var wav = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }

        wav.append(contentsOf: "RIFF".utf8); le32(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); le32(16)
        le16(1)                                        // PCM
        le16(1)                                        // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate) * 2)                   // byte rate
        le16(2)                                        // block align
        le16(16)                                       // bits per sample
        wav.append(contentsOf: "data".utf8); le32(UInt32(dataSize))
        for n in 0..<frames {
            let s = sin(2 * Double.pi * frequency * Double(n) / sampleRate)
            le16(UInt16(bitPattern: Int16(s * 12000)))
        }
        try wav.write(to: url)
    }

    /// Integration fixture: writes a real, playable Audacity session (2 WAVs + markers
    /// + LOF) to $DESGRANA_FIXTURE_DIR so it can be opened by hand in Audacity to verify
    /// the LOF import and the manual File > Import > Labels step. Skipped unless the env
    /// var is set, so it never runs in CI.
    func testAudacityIntegrationFixture() throws {
        guard let base = ProcessInfo.processInfo.environment["DESGRANA_FIXTURE_DIR"] else {
            throw XCTSkip("set DESGRANA_FIXTURE_DIR to generate the Audacity fixture")
        }
        let dir = URL(fileURLWithPath: base).appendingPathComponent("audacity_session")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sr = 48_000.0
        let left  = dir.appendingPathComponent("Take_L.wav")
        let right = dir.appendingPathComponent("Take_R.wav")
        try writePlayableWAV(to: left,  seconds: 2, frequency: 220, sampleRate: sr)
        try writePlayableWAV(to: right, seconds: 2, frequency: 440, sampleRate: sr)

        let markers: [(time: Double, name: String)] = [(0.5, "Intro"), (1.5, "Verse")]
        let lof = try generateAudacityLOF(
            wavs: [(left, 1), (right, 1)],
            duration: 2, sampleRate: sr, markers: markers, outputDir: dir)
        let labels = dir.appendingPathComponent(dir.lastPathComponent + ".txt")

        print("Audacity fixture ready:")
        print("  open \(lof.path)")
        print("  then File > Import > Labels: \(labels.path)")
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

    // MARK: - Audacity LOF

    func testLOFReferencesWavPaths() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [
            (dir.appendingPathComponent("Kick.wav"),  1),
            (dir.appendingPathComponent("OH.wav"),    2)
        ]
        let url = try generateAudacityLOF(wavs: wavs, duration: 10, sampleRate: 48000,
                                          markers: [], outputDir: dir)
        let content = try String(contentsOf: url)

        XCTAssertEqual(url.pathExtension, "lof")
        XCTAssertTrue(content.contains("file \"\(dir.appendingPathComponent("Kick.wav").path)\""))
        XCTAssertTrue(content.contains("file \"\(dir.appendingPathComponent("OH.wav").path)\""))
    }

    func testLOFWritesLabelsFileForMarkers() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [(dir.appendingPathComponent("BD.wav"), 1)]
        let url = try generateAudacityLOF(wavs: wavs, duration: 10, sampleRate: 48000,
                                          markers: [(3.5, "Verse")], outputDir: dir)
        let content = try String(contentsOf: url)

        // LOF itself carries no markers, only a pointer comment.
        XCTAssertFalse(content.contains("Verse"))
        XCTAssertTrue(content.contains("Import > Labels"))

        // Sibling labels file holds the marker as a point label (start == end).
        let labelsURL = dir.appendingPathComponent(dir.lastPathComponent + ".txt")
        let labels = try String(contentsOf: labelsURL)
        XCTAssertTrue(labels.contains("3.500000\t3.500000\tVerse"))
    }

    func testWriteAudacityLabels() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try writeAudacityLabels([(1.0, "A"), (2.5, "B")], outputDir: dir, name: "sess")
        XCTAssertEqual(note, "sess.txt")

        let labels = try String(contentsOf: dir.appendingPathComponent("sess.txt"))
        XCTAssertEqual(labels, "1.000000\t1.000000\tA\n2.500000\t2.500000\tB\n")
    }

    func testWriteAudacityLabelsNoMarkers() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = try writeAudacityLabels([], outputDir: dir, name: "sess")
        XCTAssertNil(note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sess.txt").path))
    }

    func testLOFWritesNoLabelsFileWhenNoMarkers() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavs: [(url: URL, channels: Int)] = [(dir.appendingPathComponent("BD.wav"), 1)]
        _ = try generateAudacityLOF(wavs: wavs, duration: 10, sampleRate: 48000,
                                    markers: [], outputDir: dir)

        let labelsURL = dir.appendingPathComponent(dir.lastPathComponent + ".txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: labelsURL.path))
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
