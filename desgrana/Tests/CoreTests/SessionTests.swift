// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class SessionTests: XCTestCase {

    private func fixture(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CoreTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("fixtures").appendingPathComponent(relativePath)
    }

    // MARK: - Loading

    func testLoadFixtureSession() {
        guard case .ok(let session, let dir) = Session.load(input: fixture("case05_snap/session")) else {
            return XCTFail("expected .ok")
        }
        XCTAssertEqual(dir.lastPathComponent, "session")
        XCTAssertEqual(session.takes.count, 1)
        XCTAssertNotNil(session.sessionInfo, "SE_LOG.BIN should be parsed")
        XCTAssertNotNil(session.snapInfo, "test.snap should be parsed")
        // Name comes from the snap scene (active_scene "…/Test_Scene.snap").
        XCTAssertEqual(session.sessionName, "Test_Scene")
        // OH_L/OH_R are an adjacent named pair → one stereo pair (3,4).
        XCTAssertEqual(session.snapDerivedPairs, [StereoPair(left: 3, right: 4)])
        // No SE_LOG fallbacks needed when both files are present.
        XCTAssertNil(session.inferredChannels)
        XCTAssertTrue(session.fallbackChannelNames.isEmpty)
    }

    func testLoadNonexistentIsEmpty() {
        guard case .empty = Session.load(input: URL(fileURLWithPath: "/nonexistent/path")) else {
            return XCTFail("expected .empty")
        }
    }

    // MARK: - Pair derivation

    // The divergence the extraction fixes: snap-derived pairs must merge USB hardware
    // pairs with name-detected LCL pairs. The old bridge path only did name detection.
    func testSnapDerivedMergesUsbAndLcl() {
        let snap = SnapInfo(
            usbStereoPairs: [StereoPair(left: 5, right: 6)],
            channelNames: [1: "Kick_L", 2: "Kick_R"],
            sceneName: "Scene", showName: nil
        )
        let session = Session(snapInfo: snap, inferredChannels: 8)
        XCTAssertEqual(session.snapDerivedPairs,
                       [StereoPair(left: 1, right: 2), StereoPair(left: 5, right: 6)])
    }

    // A USB pair claims its tracks; an overlapping name-detected pair on those tracks is dropped.
    func testUsbPairTakesPrecedenceOverName() {
        let snap = SnapInfo(
            usbStereoPairs: [StereoPair(left: 1, right: 2)],
            channelNames: [1: "Mix_L", 2: "Mix_R"],
            sceneName: nil, showName: nil
        )
        let session = Session(snapInfo: snap, inferredChannels: 4)
        XCTAssertEqual(session.snapDerivedPairs, [StereoPair(left: 1, right: 2)])
    }

    func testEffectivePairsHonourOverride() {
        let snap = SnapInfo(usbStereoPairs: [], channelNames: [1: "A_L", 2: "A_R"],
                            sceneName: nil, showName: nil)
        var session = Session(snapInfo: snap, inferredChannels: 4)
        XCTAssertEqual(session.effectivePairs, [StereoPair(left: 1, right: 2)])
        session.userOverridePairs = []
        XCTAssertEqual(session.effectivePairs, [], "override of [] must win over snap-derived")
    }

    func testChannelCountPrefersSeLogThenInferred() {
        XCTAssertEqual(Session(inferredChannels: 16).channelCount, 16)
        XCTAssertEqual(Session().channelCount, 0)
    }

    // MARK: - Pair editing

    func testLinkUnlinkReset() {
        let snap = SnapInfo(usbStereoPairs: [], channelNames: [1: "Kick_L", 2: "Kick_R"],
                            sceneName: nil, showName: nil)
        var session = Session(snapInfo: snap, inferredChannels: 8)
        XCTAssertEqual(session.effectivePairs, [StereoPair(left: 1, right: 2)])

        session.linkChannels(3, 4)
        XCTAssertTrue(session.isCustomized)
        XCTAssertEqual(session.effectivePairs,
                       [StereoPair(left: 1, right: 2), StereoPair(left: 3, right: 4)])

        session.unlinkPair(left: 1)
        XCTAssertEqual(session.effectivePairs, [StereoPair(left: 3, right: 4)])

        session.resetPairs()
        XCTAssertFalse(session.isCustomized)
        XCTAssertEqual(session.effectivePairs, [StereoPair(left: 1, right: 2)])
    }

    // Linking a channel already in a pair re-homes it without leaving a duplicate.
    func testLinkRehomesExistingChannel() {
        var session = Session(
            snapInfo: SnapInfo(usbStereoPairs: [], channelNames: [:], sceneName: nil, showName: nil),
            inferredChannels: 8,
            userOverridePairs: [StereoPair(left: 1, right: 2)]
        )
        session.linkChannels(2, 3)
        XCTAssertEqual(session.effectivePairs, [StereoPair(left: 2, right: 3)])
    }

    // MARK: - Progress offsets

    func testFrameOffsetsSingleTake() {
        guard case .ok(let session, _) = Session.load(input: fixture("case05_snap/session")) else {
            return XCTFail("expected .ok")
        }
        let offsets = session.frameOffsetsBeforeTakes()
        XCTAssertEqual(offsets[1], 0, "the first take starts at frame 0")
    }

    func testFrameOffsetsEmptyWithoutSeLog() {
        XCTAssertTrue(Session().frameOffsetsBeforeTakes().isEmpty)
    }
}
