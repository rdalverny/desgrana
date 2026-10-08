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

    // MARK: - Policy

    func testUnsetSettingsAreDue() {
        XCTAssertTrue(UpdateCheck.isDue(enabled: nil, intervalDays: nil, lastCheck: nil))
    }

    func testDisabledIsNeverDue() {
        XCTAssertFalse(UpdateCheck.isDue(enabled: false, intervalDays: nil, lastCheck: nil))
    }

    func testDefaultIntervalApplies() {
        XCTAssertFalse(UpdateCheck.isDue(enabled: nil, intervalDays: nil, lastCheck: daysAgo(29)))
        XCTAssertTrue(UpdateCheck.isDue(enabled: nil, intervalDays: nil, lastCheck: daysAgo(31)))
    }

    func testStoredIntervalApplies() {
        XCTAssertTrue(UpdateCheck.isDue(enabled: true, intervalDays: 7, lastCheck: daysAgo(8)))
        XCTAssertFalse(UpdateCheck.isDue(enabled: true, intervalDays: 7, lastCheck: daysAgo(6)))
    }

    func testCheckIfDueSkipsWhenDisabled() async {
        let store = MemoryStore(enabled: false)

        let info = await UpdateCheck.checkIfDue(current: "1.0.0", store: store)

        XCTAssertNil(info)
        XCTAssertNil(store.lastCheck)
    }

    func testCheckIfDueSkipsWhenRecent() async {
        let recent = daysAgo(1)
        let store = MemoryStore(lastCheck: recent)

        let info = await UpdateCheck.checkIfDue(current: "1.0.0", store: store)

        XCTAssertNil(info)
        XCTAssertEqual(store.lastCheck, recent)
    }

    private func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86_400)
    }
}

private final class MemoryStore: UpdateCheckStore {
    let enabled: Bool?
    let intervalDays: Int?
    var lastCheck: Date?

    init(enabled: Bool? = nil, intervalDays: Int? = nil, lastCheck: Date? = nil) {
        self.enabled = enabled
        self.intervalDays = intervalDays
        self.lastCheck = lastCheck
    }
}
