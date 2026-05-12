// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class DetectStereoPairsTests: XCTestCase {

    // MARK: - Separator variants

    func testUnderscoreSuffix() {
        let pairs = detectStereoPairsFromNames([1: "Kick_L", 2: "Kick_R"], channelCount: 3)
        XCTAssertEqual(pairs, [StereoPair(left: 1, right: 2)])
    }

    func testDashSuffix() {
        let pairs = detectStereoPairsFromNames([1: "Kick-L", 2: "Kick-R"], channelCount: 3)
        XCTAssertEqual(pairs, [StereoPair(left: 1, right: 2)])
    }

    func testSpaceSuffix() {
        let pairs = detectStereoPairsFromNames([1: "Kick L", 2: "Kick R"], channelCount: 3)
        XCTAssertEqual(pairs, [StereoPair(left: 1, right: 2)])
    }

    // MARK: - Non-matches

    func testMismatchedBase() {
        // Different base names must not pair.
        let pairs = detectStereoPairsFromNames([1: "Kick_L", 2: "Snare_R"], channelCount: 3)
        XCTAssertTrue(pairs.isEmpty)
    }

    func testNoSuffix() {
        let pairs = detectStereoPairsFromNames([1: "Kick", 2: "Snare"], channelCount: 3)
        XCTAssertTrue(pairs.isEmpty)
    }

    func testEmptyNames() {
        let pairs = detectStereoPairsFromNames([1: "", 2: ""], channelCount: 3)
        XCTAssertTrue(pairs.isEmpty)
    }

    func testMissingName() {
        // Channel without an entry in the dict must not pair.
        let pairs = detectStereoPairsFromNames([2: "Kick_R"], channelCount: 3)
        XCTAssertTrue(pairs.isEmpty)
    }

    func testLowercaseSuffixNotMatched() {
        // Suffix matching is case-sensitive; "_l"/"_r" must not pair.
        let pairs = detectStereoPairsFromNames([1: "Kick_l", 2: "Kick_r"], channelCount: 3)
        XCTAssertTrue(pairs.isEmpty)
    }

    // MARK: - Multiple pairs

    func testMultiplePairs() {
        let names: [Int: String] = [1: "Bus_L", 2: "Bus_R", 3: "Rev_L", 4: "Rev_R"]
        let pairs = detectStereoPairsFromNames(names, channelCount: 5)
        XCTAssertEqual(pairs, [StereoPair(left: 1, right: 2), StereoPair(left: 3, right: 4)])
    }

    func testClaimedChannelNotReused() {
        // Ch 2 is right side of pair 1-2; it must not also become left of 2-3.
        let names: [Int: String] = [1: "Bus_L", 2: "Bus_R", 3: "Bus_R"]
        let pairs = detectStereoPairsFromNames(names, channelCount: 4)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0], StereoPair(left: 1, right: 2))
    }

    // MARK: - Channel count boundary

    func testLastAdjacentPairDetected() {
        // Loop runs 1..<channelCount, so ch = channelCount-1 pairs with channelCount.
        let pairs = detectStereoPairsFromNames([3: "Out_L", 4: "Out_R"], channelCount: 5)
        XCTAssertEqual(pairs, [StereoPair(left: 3, right: 4)])
    }

    func testChannelBeyondCountIgnored() {
        // Loop runs 1..<channelCount; ch=4 is never visited as a left side when channelCount=4.
        let pairs = detectStereoPairsFromNames([4: "Out_L", 5: "Out_R"], channelCount: 4)
        XCTAssertTrue(pairs.isEmpty)
    }
}
