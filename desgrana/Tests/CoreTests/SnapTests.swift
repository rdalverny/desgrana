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
        let info = try snap(channels: ["1": ["name": "Kick", "clink": false]])
        XCTAssertEqual(info.channelNames[1], "Kick")
    }

    func testChannelNameEmptyOmitted() throws {
        let info = try snap(channels: ["1": ["name": "", "clink": false]])
        XCTAssertNil(info.channelNames[1])
    }

    func testChannelNameSanitized() throws {
        let info = try snap(channels: ["1": ["name": "Bass/Guitar", "clink": false]])
        XCTAssertEqual(info.channelNames[1], "BassGuitar")
    }

    func testChannelNameFallbackToInputRouting() throws {
        let info = try snap(
            channels: ["1": ["name": "", "clink": false,
                             "in": ["conn": ["grp": "local", "in": 1]]]],
            io: ["in": ["local": ["1": ["name": "My Input"]]]]
        )
        XCTAssertEqual(info.channelNames[1], "My_Input")
    }

    func testChannelNameDirectTakesPriorityOverRouting() throws {
        let info = try snap(
            channels: ["1": ["name": "Direct", "clink": false,
                             "in": ["conn": ["grp": "local", "in": 1]]]],
            io: ["in": ["local": ["1": ["name": "Routing"]]]]
        )
        XCTAssertEqual(info.channelNames[1], "Direct")
    }

    func testChannelNameFallbackEmptyRoutingOmitted() throws {
        let info = try snap(
            channels: ["1": ["name": "", "clink": false,
                             "in": ["conn": ["grp": "local", "in": 1]]]],
            io: ["in": ["local": ["1": ["name": ""]]]]
        )
        XCTAssertNil(info.channelNames[1])
    }

    // MARK: - Stereo pairs

    func testStereoPairBasic() throws {
        let info = try snap(channels: [
            "1": ["name": "", "clink": true],
            "2": ["name": "", "clink": true]
        ])
        XCTAssertEqual(info.stereoPairs.count, 1)
        XCTAssertEqual(info.stereoPairs[0].left, 1)
        XCTAssertEqual(info.stereoPairs[0].right, 2)
    }

    func testStereoPairRightSideNotDuplicated() throws {
        // Wing sets clink=true on both channels; channel 2 must not produce a second pair.
        let info = try snap(channels: [
            "1": ["name": "", "clink": true],
            "2": ["name": "", "clink": true]
        ])
        XCTAssertEqual(info.stereoPairs.count, 1)
    }

    func testMultipleStereoPairs() throws {
        let info = try snap(channels: [
            "1": ["name": "", "clink": true],
            "2": ["name": "", "clink": true],
            "3": ["name": "", "clink": true],
            "4": ["name": "", "clink": true]
        ])
        XCTAssertEqual(info.stereoPairs.count, 2)
        XCTAssertEqual(info.stereoPairs[0].left, 1)
        XCTAssertEqual(info.stereoPairs[1].left, 3)
    }

    func testNoPairsWhenClinkFalse() throws {
        let info = try snap(channels: [
            "1": ["name": "Kick", "clink": false],
            "2": ["name": "Snare", "clink": false]
        ])
        XCTAssertTrue(info.stereoPairs.isEmpty)
    }

    func testNoPairsWhenClinkAbsent() throws {
        let info = try snap(channels: ["1": ["name": "Kick"]])
        XCTAssertTrue(info.stereoPairs.isEmpty)
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
