// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

private let windows11FirstBuild = 22_000
private let osReleasePath = "/etc/os-release"
private let linuxFallback = "linux"
private let unknown = "unknown"

/// Host platform labels, as sent by the update check and written in reports.
enum Platform {

    static var os: String {
        #if os(macOS)
        return "macos"
        #elseif os(Windows)
        return "windows"
        #elseif os(Linux)
        return "linux"
        #else
        return unknown
        #endif
    }

    /// "15" on macOS, "11" on Windows, "debian12" on Linux.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion

        #if os(macOS)
        return "\(v.majorVersion)"
        #elseif os(Windows)
        return windowsVersion(build: v.patchVersion)
        #else
        guard let content = try? String(contentsOfFile: osReleasePath, encoding: .utf8) else {
            return linuxFallback
        }
        return linuxVersion(osRelease: content)
        #endif
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return unknown
        #endif
    }

    // Windows 11 still reports major version 10: only the build tells them apart.
    // Foundation puts the build number in patchVersion.
    static func windowsVersion(build: Int) -> String {
        build >= windows11FirstBuild ? "11" : "10"
    }

    static func linuxVersion(osRelease: String) -> String {
        var id = linuxFallback
        var version = ""

        for line in osRelease.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0])
            let val = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key == "ID" { id = val }
            if key == "VERSION_ID" { version = val.components(separatedBy: ".").first ?? val }
        }

        return id + version
    }
}
