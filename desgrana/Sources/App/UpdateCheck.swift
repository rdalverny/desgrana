// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

private let lastCheckKey = "UpdateCheck.lastDate"
let updateCheckEnabledKey = "UpdateCheck.enabled"
let updateCheckIntervalKey = "UpdateCheck.intervalDays"
private let defaultIntervalDays = 30

struct UpdateInfo {
    let version: String
    let notes: String
    let url: URL?
}

struct UpdateCheck {
    /// Checks only if enabled and the configured interval has elapsed since the last check.
    static func checkIfDue(current: String) async -> UpdateInfo? {
        let enabled = UserDefaults.standard.object(forKey: updateCheckEnabledKey) as? Bool ?? true
        guard enabled else { return nil }
        let days = UserDefaults.standard.object(forKey: updateCheckIntervalKey) as? Int ?? defaultIntervalDays
        let interval = TimeInterval(days) * 24 * 60 * 60
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return nil }
        return await checkNow(current: current)
    }

    /// Always checks, regardless of when the last check happened.
    static func checkNow(current: String) async -> UpdateInfo? {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        return await fetch(current: current)
    }

    private static func fetch(current: String) async -> UpdateInfo? {
        guard let (data, _) = try? await URLSession.shared.data(from: buildURL(current: current)),
              let json = try? JSONDecoder().decode([String: String].self, from: data),
              let latest = json["version"],
              latest.compare(current, options: .numeric) == .orderedDescending
        else { return nil }
        return UpdateInfo(
            version: latest,
            notes: json["notes"] ?? "",
            url: json["url"].flatMap(URL.init)
        )
    }

    private static func buildURL(current: String) -> URL {
        var comps = URLComponents(string: Constants.URLs.versionFeed)!
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        comps.queryItems = [
            URLQueryItem(name: "os",   value: platformOS()),
            URLQueryItem(name: "osv",  value: platformOSV()),
            URLQueryItem(name: "arch", value: platformArch()),
            URLQueryItem(name: "v",    value: current),
            URLQueryItem(name: "l",    value: lang),
        ]
        return comps.url!
    }

    private static func platformOS() -> String {
        #if os(macOS)
        return "macos"
        #else
        return "linux"
        #endif
    }

    private static func platformOSV() -> String {
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
            if key == "ID"         { id = val }
            if key == "VERSION_ID" { version = val.components(separatedBy: ".").first ?? val }
        }
        return id + version
        #endif
    }

    private static func platformArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
