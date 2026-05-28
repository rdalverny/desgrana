// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class SnapTests: XCTestCase {

    // Writes JSON to a temp file, parses it, removes the file.
    private func parse(_ json: String) throws -> SnapInfo {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".snap")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try parseSnap(at: tmp)
    }

    // Builds a minimal valid snap JSON from structured args and parses it.
    private func snap(
        channels: [String: Any] = [:],
        io: [String: Any]? = nil,
        activeScene: String? = nil
    ) throws -> SnapInfo {
        var ae: [String: Any] = ["ch": channels]
        if let io { ae["io"] = io }
        var root: [String: Any] = ["ae_data": ae]
        if let activeScene { root["active_scene"] = activeScene }
        let data = try JSONSerialization.data(withJSONObject: root)
        return try parse(String(data: data, encoding: .utf8)!)
    }

    // MARK: - Errors

    func testMissingFile() {
        XCTAssertThrowsError(try parseSnap(at: URL(fileURLWithPath: "/nonexistent/path.snap"))) {
            guard case SnapError.cannotRead = $0 else {
                XCTFail("Expected cannotRead, got \($0)"); return
            }
        }
    }

    func testInvalidJSON() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".snap")
        try "not json".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertThrowsError(try parseSnap(at: tmp)) {
            guard case SnapError.invalidJSON = $0 else {
                XCTFail("Expected invalidJSON, got \($0)"); return
            }
        }
    }

    func testMissingChannelData() throws {
        XCTAssertThrowsError(try parse(#"{"ae_data": {}}"#)) {
            guard case SnapError.missingChannelData = $0 else {
                XCTFail("Expected missingChannelData, got \($0)"); return
            }
        }
    }

    // MARK: - Channel names

    func testChannelNameDirect() throws {
        let info = try snap(channels: ["1": ["name": "Kick"]])
        XCTAssertEqual(info.channelNames[1], "Kick")
    }

    func testChannelNameEmptyOmitted() throws {
        let info = try snap(channels: ["1": ["name": ""]])
        XCTAssertNil(info.channelNames[1])
    }

    func testChannelNameSanitized() throws {
        let info = try snap(channels: ["1": ["name": "Bass/Guitar"]])
        XCTAssertEqual(info.channelNames[1], "BassGuitar")
    }

    func testChannelNameFallbackToInputRouting() throws {
        let info = try snap(
            channels: ["1": ["name": "",
                             "in": ["conn": ["grp": "local", "in": 1]]]],
            io: ["in": ["local": ["1": ["name": "My Input"]]]]
        )
        XCTAssertEqual(info.channelNames[1], "My_Input")
    }

    func testChannelNameDirectTakesPriorityOverRouting() throws {
        let info = try snap(
            channels: ["1": ["name": "Direct",
                             "in": ["conn": ["grp": "local", "in": 1]]]],
            io: ["in": ["local": ["1": ["name": "Routing"]]]]
        )
        XCTAssertEqual(info.channelNames[1], "Direct")
    }

    func testChannelNameFallbackEmptyRoutingOmitted() throws {
        let info = try snap(
            channels: ["1": ["name": "",
                             "in": ["conn": ["grp": "local", "in": 1]]]],
            io: ["in": ["local": ["1": ["name": ""]]]]
        )
        XCTAssertNil(info.channelNames[1])
    }

    // MARK: - USB stereo pairs

    // Wing USB stereo: stereo is indicated by io.in.USB.N.mode="ST".
    // The pair is (usbIn, usbIn+1) and the name is keyed by usbIn, not by Wing channel number.
    func testUsbStereoChannelProducesPair() throws {
        let info = try snap(
            channels: ["1": ["name": "BD",
                             "in": ["conn": ["grp": "USB", "in": 1]]]],
            io: ["in": ["USB": ["1": ["mode": "ST"]]]]
        )
        XCTAssertEqual(info.usbStereoPairs.count, 1)
        XCTAssertEqual(info.usbStereoPairs[0].left,  1)
        XCTAssertEqual(info.usbStereoPairs[0].right, 2)
        // Name keyed by WAV track 1 (= USB in 1), not Wing ch 1 (same here, but explicit)
        XCTAssertEqual(info.channelNames[1], "BD")
        XCTAssertNil(info.channelNames[2])
    }

    func testUsbMonoChannelNoPair() throws {
        let info = try snap(
            channels: ["1": ["name": "BD",
                             "in": ["conn": ["grp": "USB", "in": 1]]]],
            io: ["in": ["USB": ["1": ["mode": "M"]]]]
        )
        XCTAssertTrue(info.usbStereoPairs.isEmpty)
    }

    func testUsbMidSideChannelProducesPair() throws {
        let info = try snap(
            channels: ["1": ["name": "OH",
                             "in": ["conn": ["grp": "USB", "in": 3]]]],
            io: ["in": ["USB": ["3": ["mode": "M/S"]]]]
        )
        XCTAssertEqual(info.usbStereoPairs.count, 1)
        XCTAssertEqual(info.usbStereoPairs[0].left,  3)
        XCTAssertEqual(info.usbStereoPairs[0].right, 4)
        XCTAssertEqual(info.channelNames[3], "OH")
    }

    // Reproduces the reported bug: 4 Wing channels in ST/USB mode, each taking 2 WAV tracks.
    // Wing ch1=BD(USB1+2), ch2=SD(USB3+4), ch3=Toms(USB5+6), ch4=OH(USB7+8).
    // Expected: 4 pairs keyed by USB input number; names keyed by left USB track.
    func testUsbStereoFourChannels() throws {
        let channels: [String: Any] = [
            "1": ["name": "BD",   "in": ["conn": ["grp": "USB", "in": 1]]],
            "2": ["name": "SD",   "in": ["conn": ["grp": "USB", "in": 3]]],
            "3": ["name": "Toms", "in": ["conn": ["grp": "USB", "in": 5]]],
            "4": ["name": "OH",   "in": ["conn": ["grp": "USB", "in": 7]]]
        ]
        let io: [String: Any] = ["in": ["USB": [
            "1": ["mode": "ST"], "3": ["mode": "ST"],
            "5": ["mode": "ST"], "7": ["mode": "ST"]
        ]]]
        let info = try snap(channels: channels, io: io)

        XCTAssertEqual(info.usbStereoPairs.count, 4)
        let lefts = info.usbStereoPairs.map(\.left)
        XCTAssertEqual(lefts, [1, 3, 5, 7])
        let rights = info.usbStereoPairs.map(\.right)
        XCTAssertEqual(rights, [2, 4, 6, 8])

        XCTAssertEqual(info.channelNames[1], "BD")
        XCTAssertEqual(info.channelNames[3], "SD")
        XCTAssertEqual(info.channelNames[5], "Toms")
        XCTAssertEqual(info.channelNames[7], "OH")
        // Right-side USB tracks have no name
        XCTAssertNil(info.channelNames[2])
        XCTAssertNil(info.channelNames[4])
        XCTAssertNil(info.channelNames[6])
        XCTAssertNil(info.channelNames[8])
    }

    // MARK: - Real snap fixture

    // Parses the real Wing Rack snap from the bug reporter (case07_usb_stereo).
    // 4 Wing channels with USB stereo sources (BD/SD/Toms/OH on USB 1,3,5,7),
    // plus LCL channels with overlapping track numbers.
    // Verifies that USB stereo pairs and names are correct with no duplicates.
    func testRealSnapUsbStereo() throws {
        let snapURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // CoreTests/
            .deletingLastPathComponent()          // Tests/
            .appendingPathComponent("fixtures/case07_usb_stereo/session/USB_Stereo.snap")
        let info = try parseSnap(at: snapURL)

        // The 4 USB stereo pairs must appear exactly once each, in order.
        let lefts = info.usbStereoPairs.map(\.left)
        XCTAssertTrue(lefts.contains(1), "missing BD pair")
        XCTAssertTrue(lefts.contains(3), "missing SD pair")
        XCTAssertTrue(lefts.contains(5), "missing Toms pair")
        XCTAssertTrue(lefts.contains(7), "missing OH pair")

        // No duplicates.
        XCTAssertEqual(lefts.count, Set(lefts).count, "duplicate pairs found: \(lefts)")

        // Names keyed by USB input number (= left WAV track), not Wing channel number.
        XCTAssertEqual(info.channelNames[1], "BD")
        XCTAssertEqual(info.channelNames[3], "SD")
        XCTAssertEqual(info.channelNames[5], "Toms")
        XCTAssertEqual(info.channelNames[7], "OH")

        // Right-side USB tracks have no name.
        XCTAssertNil(info.channelNames[2])
        XCTAssertNil(info.channelNames[4])
        XCTAssertNil(info.channelNames[6])
        XCTAssertNil(info.channelNames[8])
    }

    // MARK: - Scene and show names

    func testActiveSceneWindowsPath() throws {
        let info = try snap(activeScene: "I:/ROCK THE END/LIVE TRIPLE B.snap")
        XCTAssertEqual(info.sceneName, "LIVE TRIPLE B")
        XCTAssertEqual(info.showName, "ROCK THE END")
    }

    func testActiveSceneBackslashes() throws {
        let info = try snap(activeScene: "I:\\ROCK THE END\\LIVE TRIPLE B.snap")
        XCTAssertEqual(info.sceneName, "LIVE TRIPLE B")
        XCTAssertEqual(info.showName, "ROCK THE END")
    }

    func testActiveSceneNoDriveLetter() throws {
        let info = try snap(activeScene: "MY SHOW/MY SCENE.snap")
        XCTAssertEqual(info.sceneName, "MY SCENE")
        XCTAssertEqual(info.showName, "MY SHOW")
    }

    func testActiveSceneSingleComponent() throws {
        let info = try snap(activeScene: "SCENE.snap")
        XCTAssertEqual(info.sceneName, "SCENE")
        XCTAssertNil(info.showName)
    }

    func testActiveSceneDriveLetterSkipsShowName() throws {
        // "I:" has count <= 2 so it is treated as a drive letter and not set as showName.
        let info = try snap(activeScene: "I:/SCENE.snap")
        XCTAssertEqual(info.sceneName, "SCENE")
        XCTAssertNil(info.showName)
    }

    func testActiveSceneAbsent() throws {
        let info = try snap()
        XCTAssertNil(info.sceneName)
        XCTAssertNil(info.showName)
    }

    func testActiveSceneEmpty() throws {
        let info = try snap(activeScene: "")
        XCTAssertNil(info.sceneName)
        XCTAssertNil(info.showName)
    }
}
