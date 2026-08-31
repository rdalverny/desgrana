// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

/// Escalating snapshot discovery (session dir → parent → volume root) and the
/// size cap guarding the parsers against an oversized file.
final class SnapDiscoveryTests: XCTestCase {

    private let fm = FileManager.default

    // A unique temp directory, cleaned up after the test.
    private func makeDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? self.fm.removeItem(at: dir) }
        return dir
    }

    private func writeSnapshot(_ name: String, in dir: URL) throws {
        try "{}".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - Discovery

    func testSnapshotInSessionDir() throws {
        let session = try makeDir()
        try writeSnapshot("show.snap", in: session)

        guard case .inSession(let url) = discoverSnapshot(sessionDir: session) else {
            return XCTFail("expected .inSession")
        }
        XCTAssertEqual(url.lastPathComponent, "show.snap")
    }

    func testSingleSnapshotInParentIsSuggested() throws {
        let parent = try makeDir()
        let session = parent.appendingPathComponent("takes", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try writeSnapshot("show.snap", in: parent)

        guard case .suggested(let url) = discoverSnapshot(sessionDir: session) else {
            return XCTFail("expected .suggested")
        }
        XCTAssertEqual(url.lastPathComponent, "show.snap")
    }

    func testX32SceneInParentIsSuggested() throws {
        let parent = try makeDir()
        let session = parent.appendingPathComponent("takes", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try writeSnapshot("show.scn", in: parent)

        guard case .suggested(let url) = discoverSnapshot(sessionDir: session) else {
            return XCTFail("expected .suggested")
        }
        XCTAssertEqual(url.lastPathComponent, "show.scn")
    }

    func testSeveralSnapshotsNearbyStaySilent() throws {
        let parent = try makeDir()
        let session = parent.appendingPathComponent("takes", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try writeSnapshot("a.snap", in: parent)
        try writeSnapshot("b.snap", in: parent)

        XCTAssertEqual(discoverSnapshot(sessionDir: session), .none)
    }

    func testNoSnapshotAnywhere() throws {
        let parent = try makeDir()
        let session = parent.appendingPathComponent("takes", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)

        XCTAssertEqual(discoverSnapshot(sessionDir: session), .none)
    }

    // MARK: - Size cap

    func testOversizedSnapshotRejected() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("huge.snap")
        // Just over the cap: the guard runs before any parsing, so content is irrelevant.
        let data = Data(count: Constants.Format.snapMaxBytes + 1)
        try data.write(to: url)

        XCTAssertThrowsError(try parseSnap(at: url)) {
            guard case SnapshotFileError.tooLarge = $0 else {
                return XCTFail("expected .tooLarge, got \($0)")
            }
        }
    }
}
