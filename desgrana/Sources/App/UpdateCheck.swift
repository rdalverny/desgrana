// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation

private let lastCheckKey = "UpdateCheck.lastDate"
private let checkInterval: TimeInterval = 2 * 24 * 60 * 60

struct UpdateInfo {
    let version: String
    let notes: String
    let url: URL?
}

struct UpdateCheck {
    static let feedURL = URL(string: "https://rdalverny.github.io/desgrana/version.json")!

    /// Checks only if 2 days have elapsed since the last check.
    static func checkIfDue(current: String) async -> UpdateInfo? {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= checkInterval else { return nil }
        return await checkNow(current: current)
    }

    /// Always checks, regardless of when the last check happened.
    static func checkNow(current: String) async -> UpdateInfo? {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        return await fetch(current: current)
    }

    private static func fetch(current: String) async -> UpdateInfo? {
        guard let (data, _) = try? await URLSession.shared.data(from: feedURL),
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
}
