// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class UpdateCheckTests: XCTestCase {

    // MARK: - Basic ordering

    func testOlderVersionIsNewer() {
        XCTAssertTrue(isNewerVersion("1.8.1", than: "1.0.0"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(isNewerVersion("1.8.1", than: "1.8.1"))
    }

    func testFutureVersionIsNotNewer() {
        XCTAssertFalse(isNewerVersion("1.8.1", than: "99.0.0"))
    }

    // MARK: - Numeric vs lexicographic

    func testNumericComparisonMinorTwoDigits() {
        // "1.10.0" > "1.9.0" — fails with lexicographic comparison
        XCTAssertTrue(isNewerVersion("1.10.0", than: "1.9.0"))
    }

    func testNumericComparisonPatchTwoDigits() {
        XCTAssertTrue(isNewerVersion("1.8.10", than: "1.8.9"))
    }

    // MARK: - Patch-level updates

    func testPatchUpdateDetected() {
        XCTAssertTrue(isNewerVersion("1.8.2", than: "1.8.1"))
    }

    func testMinorUpdateDetected() {
        XCTAssertTrue(isNewerVersion("1.9.0", than: "1.8.1"))
    }

    func testMajorUpdateDetected() {
        XCTAssertTrue(isNewerVersion("2.0.0", than: "1.8.1"))
    }

    // MARK: - isUpdateDue

    func testUpdateDueWhenNeverChecked() {
        XCTAssertTrue(isUpdateDue(lastCheckEpoch: 0, intervalDays: 30))
    }

    func testUpdateNotDueWhenRecentlyChecked() {
        let oneHourAgo = Int64(Date().timeIntervalSince1970) - 3_600
        XCTAssertFalse(isUpdateDue(lastCheckEpoch: oneHourAgo, intervalDays: 30))
    }

    func testUpdateDueWhenIntervalElapsed() {
        let thirtyOneDaysAgo = Int64(Date().timeIntervalSince1970) - 31 * 86_400
        XCTAssertTrue(isUpdateDue(lastCheckEpoch: thirtyOneDaysAgo, intervalDays: 30))
    }

    func testUpdateDueAtExactBoundary() {
        // exactly 30 days ago — boundary counts as due (>= comparison)
        let exactly = Int64(Date().timeIntervalSince1970) - 30 * 86_400
        XCTAssertTrue(isUpdateDue(lastCheckEpoch: exactly, intervalDays: 30))
    }

    func testCustomIntervalRespected() {
        let twoDaysAgo = Int64(Date().timeIntervalSince1970) - 2 * 86_400
        XCTAssertFalse(isUpdateDue(lastCheckEpoch: twoDaysAgo, intervalDays: 7))
        XCTAssertTrue(isUpdateDue(lastCheckEpoch: twoDaysAgo, intervalDays: 1))
    }
}
