// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class X32SceneTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ content: String, filename: String = "MyScene.scn") throws -> SnapInfo {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try parseX32Scene(at: tmp)
    }

    // MARK: - Channel names

    func testChannelNameBasic() throws {
        let info = try parse("""
        /ch/01/config/name "Kick"
        /ch/02/config/name "Snare Top"
        """)
        XCTAssertEqual(info.channelNames[1], "Kick")
        XCTAssertEqual(info.channelNames[2], "Snare_Top")
    }

    func testChannelNameAllThirtyTwo() throws {
        var lines = (1...32).map { String(format: "/ch/%02d/config/name \"Ch%02d\"", $0, $0) }
        lines.append("")  // trailing newline
        let info = try parse(lines.joined(separator: "\n"))
        XCTAssertEqual(info.channelNames.count, 32)
        XCTAssertEqual(info.channelNames[32], "Ch32")
    }

    func testEmptyNameIsOmitted() throws {
        let info = try parse("""
        /ch/01/config/name ""
        /ch/02/config/name "Snare"
        """)
        XCTAssertNil(info.channelNames[1])
        XCTAssertEqual(info.channelNames[2], "Snare")
    }

    func testChannelNameWithSpaces() throws {
        let info = try parse(#"/ch/01/config/name "Kick Drum Low""#)
        XCTAssertEqual(info.channelNames[1], "Kick_Drum_Low")
    }

    func testChannelNameUnsafeChars() throws {
        let info = try parse(#"/ch/01/config/name "Bass/Guitar""#)
        XCTAssertEqual(info.channelNames[1], "BassGuitar")
    }

    // MARK: - Stereo pairs

    func testStereoPairOnFormat1() throws {
        let info = try parse("""
        /config/chlink1-2 ON
        /config/chlink3-4 OFF
        """)
        XCTAssertEqual(info.stereoPairs.count, 1)
        XCTAssertEqual(info.stereoPairs[0].left, 1)
        XCTAssertEqual(info.stereoPairs[0].right, 2)
    }

    func testStereoPairZeroPaddedFormat() throws {
        let info = try parse("""
        /config/chlink01-02 ON
        /config/chlink03-04 ON
        """)
        XCTAssertEqual(info.stereoPairs.count, 2)
        XCTAssertEqual(info.stereoPairs[1].left, 3)
        XCTAssertEqual(info.stereoPairs[1].right, 4)
    }

    func testStereoPairNumeric1() throws {
        let info = try parse("/config/chlink5-6 1")
        XCTAssertEqual(info.stereoPairs.count, 1)
        XCTAssertEqual(info.stereoPairs[0].left, 5)
    }

    func testStereoPairOff() throws {
        let info = try parse("/config/chlink1-2 OFF")
        XCTAssertTrue(info.stereoPairs.isEmpty)
    }

    func testStereoPairNumericZero() throws {
        let info = try parse("/config/chlink1-2 0")
        XCTAssertTrue(info.stereoPairs.isEmpty)
    }

    // MARK: - Scene name

    func testSceneNamePresent() throws {
        let info = try parse(#"/show/name "My Live Show""#)
        XCTAssertEqual(info.sceneName, "My Live Show")
    }

    func testSceneNameAbsentFallsBackToFilename() throws {
        let info = try parse("/ch/01/config/name \"Kick\"", filename: "ROCK_SHOW.scn")
        XCTAssertEqual(info.sceneName, "ROCK_SHOW")
    }

    // MARK: - Malformed / edge-case lines

    func testCommentLinesIgnored() throws {
        let info = try parse("""
        # This is a comment
        /ch/01/config/name "Kick"
        """)
        XCTAssertEqual(info.channelNames[1], "Kick")
    }

    func testBarePathNoValue() throws {
        XCTAssertNoThrow(try parse("/ch/01/config/name"))
        let info = try parse("/ch/01/config/name")
        XCTAssertTrue(info.channelNames.isEmpty)
    }

    func testUnknownPathIgnored() throws {
        XCTAssertNoThrow(try parse("/some/unknown/path 42"))
        let info = try parse("/some/unknown/path 42\n/ch/01/config/name \"Kick\"")
        XCTAssertEqual(info.channelNames[1], "Kick")
    }

    func testEmptyFile() throws {
        let info = try parse("")
        XCTAssertTrue(info.channelNames.isEmpty)
        XCTAssertTrue(info.stereoPairs.isEmpty)
    }

    func testBlankLinesIgnored() throws {
        let info = try parse("\n\n/ch/01/config/name \"Kick\"\n\n")
        XCTAssertEqual(info.channelNames[1], "Kick")
    }
}

// MARK: - sanitizeChannelName tests

final class SanitizeChannelNameTests: XCTestCase {
    func testUnsafeCharsRemoved() {
        XCTAssertEqual(sanitizeChannelName("Bass/Guitar"), "BassGuitar")
        XCTAssertEqual(sanitizeChannelName("Kick:Drum"), "KickDrum")
    }

    func testLeadingTrailingSpacesTrimmed() {
        XCTAssertEqual(sanitizeChannelName("  Kick  "), "Kick")
    }

    func testInternalSpacesCollapsedToUnderscore() {
        XCTAssertEqual(sanitizeChannelName("Kick Drum"), "Kick_Drum")
        XCTAssertEqual(sanitizeChannelName("Kick  Drum"), "Kick_Drum")
    }
}
