// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

// MARK: - Version comparison

/// Returns true if `latest` is strictly greater than `current`.
/// Uses numeric component comparison ("1.10.0" > "1.9.0"), mirroring
/// Swift's String.compare(_:options:) with .numeric.
public func isNewerVersion(_ latest: String, than current: String) -> Bool {
    latest.compare(current, options: .numeric) == .orderedDescending
}

/// Returns true if enough time has elapsed since `lastCheckEpoch` to warrant
/// a new update check. Pass 0 for `lastCheckEpoch` to force a check.
public func isUpdateDue(lastCheckEpoch: Int64, intervalDays: Int) -> Bool {
    let elapsed = Date().timeIntervalSince1970 - Double(lastCheckEpoch)
    return elapsed >= Double(intervalDays) * 86_400
}

// MARK: - Remote fetch

public struct UpdateInfo: Sendable {
    public let version: String
    public let notes: String
    public let url: URL?
}

/// Fetches the remote version feed and returns an `UpdateInfo` if a newer
/// version than `current` is available, nil otherwise (including on error).
public func fetchUpdate(current: String) async -> UpdateInfo? {
    guard let url = buildUpdateURL(current: current),
          let (data, _) = try? await URLSession.shared.data(from: url),
          let json = try? JSONDecoder().decode([String: String].self, from: data),
          let latest = json["version"],
          isNewerVersion(latest, than: current)
    else { return nil }
    return UpdateInfo(
        version: latest,
        notes: json["notes"] ?? "",
        url: json["url"].flatMap(URL.init)
    )
}

private func buildUpdateURL(current: String) -> URL? {
    guard var comps = URLComponents(string: Constants.URLs.versionFeed) else { return nil }
    let lang = Locale.current.language.languageCode?.identifier ?? "en"
    comps.queryItems = [
        URLQueryItem(name: "os",   value: updatePlatformOS()),
        URLQueryItem(name: "osv",  value: updatePlatformOSV()),
        URLQueryItem(name: "arch", value: updatePlatformArch()),
        URLQueryItem(name: "v",    value: current),
        URLQueryItem(name: "l",    value: lang)
    ]
    return comps.url
}

private func updatePlatformOS() -> String {
    #if os(macOS)
    return "macos"
    #else
    return "linux"
    #endif
}

private func updatePlatformOSV() -> String {
    #if os(macOS)
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion)"
    #else
    guard let content = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
        return "linux"
    }
    var id = "linux"
    var version = ""
    for line in content.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = String(parts[0])
        let val = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if key == "ID" { id = val }
        if key == "VERSION_ID" { version = val.components(separatedBy: ".").first ?? val }
    }
    return id + version
    #endif
}

private func updatePlatformArch() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
