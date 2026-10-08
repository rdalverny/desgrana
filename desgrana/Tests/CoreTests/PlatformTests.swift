// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import XCTest
@testable import DesgranaCore

final class PlatformTests: XCTestCase {

    func testOSMatchesHost() {
        #if os(macOS)
        XCTAssertEqual(Platform.os, "macos")
        #elseif os(Windows)
        XCTAssertEqual(Platform.os, "windows")
        #elseif os(Linux)
        XCTAssertEqual(Platform.os, "linux")
        #endif
    }

    func testOSVersionIsNotLinuxFallbackOffLinux() {
        #if !os(Linux)
        XCTAssertNotEqual(Platform.osVersion, "linux")
        #endif
    }

    // MARK: - Windows

    func testWindows10Build() {
        XCTAssertEqual(Platform.windowsVersion(build: 19045), "10")
    }

    func testWindows11FirstBuild() {
        XCTAssertEqual(Platform.windowsVersion(build: 22000), "11")
    }

    func testWindows11RecentBuild() {
        XCTAssertEqual(Platform.windowsVersion(build: 26100), "11")
    }

    // MARK: - Linux

    func testLinuxDebian() {
        let osRelease = """
            ID=debian
            VERSION_ID="12"
            """
        XCTAssertEqual(Platform.linuxVersion(osRelease: osRelease), "debian12")
    }

    func testLinuxUbuntuKeepsMajorOnly() {
        let osRelease = """
            ID=ubuntu
            VERSION_ID="24.04"
            """
        XCTAssertEqual(Platform.linuxVersion(osRelease: osRelease), "ubuntu24")
    }

    func testLinuxWithoutVersion() {
        XCTAssertEqual(Platform.linuxVersion(osRelease: "ID=arch"), "arch")
    }
}
