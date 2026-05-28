// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore

private let lastCheckKey = "UpdateCheck.lastDate"
let updateCheckEnabledKey  = "UpdateCheck.enabled"
let updateCheckIntervalKey = "UpdateCheck.intervalDays"
private let defaultIntervalDays = 30

struct UpdateCheck {
    /// Fetches only if enabled and the configured interval has elapsed.
    static func checkIfDue(current: String) async -> UpdateInfo? {
        let enabled = UserDefaults.standard.object(forKey: updateCheckEnabledKey) as? Bool ?? true
        guard enabled else { return nil }
        let days      = UserDefaults.standard.object(forKey: updateCheckIntervalKey) as? Int ?? defaultIntervalDays
        let lastEpoch = Int64((UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast)
                                  .timeIntervalSince1970)
        guard isUpdateDue(lastCheckEpoch: lastEpoch, intervalDays: days) else { return nil }
        return await checkNow(current: current)
    }

    /// Always fetches, regardless of when the last check happened.
    static func checkNow(current: String) async -> UpdateInfo? {
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        return await fetchUpdate(current: current)
    }
}
