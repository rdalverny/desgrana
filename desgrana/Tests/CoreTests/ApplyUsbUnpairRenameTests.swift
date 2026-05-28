// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class ApplyUsbUnpairRenameTests: XCTestCase {

    // No USB pairs — names unchanged.
    func testNoUsbPairs() {
        let names = applyUsbUnpairRename(
            names: [1: "Kick", 2: "Snare"],
            usbPairs: [],
            activePairs: []
        )
        XCTAssertEqual(names, [1: "Kick", 2: "Snare"])
    }

    // USB pair still active — names unchanged.
    func testUsbPairStillActive() {
        let usb = StereoPair(left: 1, right: 2)
        let names = applyUsbUnpairRename(
            names: [1: "BD"],
            usbPairs: [usb],
            activePairs: [usb]
        )
        XCTAssertEqual(names[1], "BD")
        XCTAssertNil(names[2])
    }

    // USB pair unlinked — both tracks get _L/_R suffix.
    func testUsbPairUnlinkedRenamesBothTracks() {
        let names = applyUsbUnpairRename(
            names: [1: "BD"],
            usbPairs: [StereoPair(left: 1, right: 2)],
            activePairs: []
        )
        XCTAssertEqual(names[1], "BD_L")
        XCTAssertEqual(names[2], "BD_R")
    }

    // Unnamed left track falls back to ch<N> base.
    func testUnnamedLeftTrackFallsBackToChN() {
        let names = applyUsbUnpairRename(
            names: [:],
            usbPairs: [StereoPair(left: 3, right: 4)],
            activePairs: []
        )
        XCTAssertEqual(names[3], "ch3_L")
        XCTAssertEqual(names[4], "ch3_R")
    }

    // Multiple USB pairs: one active, one unlinked.
    func testMixedActiveAndUnlinked() {
        let active = StereoPair(left: 1, right: 2)
        let unlinked = StereoPair(left: 3, right: 4)
        let names = applyUsbUnpairRename(
            names: [1: "BD", 3: "OH"],
            usbPairs: [active, unlinked],
            activePairs: [active]
        )
        XCTAssertEqual(names[1], "BD")
        XCTAssertNil(names[2])
        XCTAssertEqual(names[3], "OH_L")
        XCTAssertEqual(names[4], "OH_R")
    }
}
