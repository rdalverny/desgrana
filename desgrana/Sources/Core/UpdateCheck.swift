// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let secondsPerDay = 86_400.0

/// Where each UI persists its update-check settings (UserDefaults, QSettings...).
/// nil means unset: the policy defaults apply.
public protocol UpdateCheckStore {
    var enabled: Bool? { get }
    var intervalDays: Int? { get }
    var lastCheck: Date? { get nonmutating set }
}

public enum UpdateCheck {

    public static let defaultEnabled = true
    public static let defaultIntervalDays = 30

    public static func isDue(enabled: Bool?, intervalDays: Int?, lastCheck: Date?) -> Bool {
        guard enabled ?? defaultEnabled else { return false }

        let lastEpoch = Int64((lastCheck ?? .distantPast).timeIntervalSince1970)
        return isUpdateDue(lastCheckEpoch: lastEpoch, intervalDays: intervalDays ?? defaultIntervalDays)
    }

    /// Fetches only if enabled and the configured interval has elapsed.
    public static func checkIfDue(current: String, store: UpdateCheckStore) async -> UpdateInfo? {
        guard isDue(enabled: store.enabled, intervalDays: store.intervalDays, lastCheck: store.lastCheck) else {
            return nil
        }
        return await checkNow(current: current, store: store)
    }

    /// Always fetches, regardless of when the last check happened.
    public static func checkNow(current: String, store: UpdateCheckStore) async -> UpdateInfo? {
        store.lastCheck = Date()
        return await fetchUpdate(current: current)
    }
}

/// Returns true if enough time has elapsed since `lastCheckEpoch` to warrant
/// a new update check. Pass 0 for `lastCheckEpoch` to force a check.
public func isUpdateDue(lastCheckEpoch: Int64, intervalDays: Int) -> Bool {
    let elapsed = Date().timeIntervalSince1970 - Double(lastCheckEpoch)
    return elapsed >= Double(intervalDays) * secondsPerDay
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
        URLQueryItem(name: "os",   value: Platform.os),
        URLQueryItem(name: "osv",  value: Platform.osVersion),
        URLQueryItem(name: "arch", value: Platform.arch),
        URLQueryItem(name: "v",    value: current),
        URLQueryItem(name: "l",    value: lang)
    ]
    return comps.url
}
