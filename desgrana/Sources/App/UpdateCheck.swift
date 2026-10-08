// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import Foundation
import DesgranaCore

private let lastCheckKey = "UpdateCheck.lastDate"
let updateCheckEnabledKey  = "UpdateCheck.enabled"
let updateCheckIntervalKey = "UpdateCheck.intervalDays"

struct UserDefaultsUpdateStore: UpdateCheckStore {
    var enabled: Bool? {
        UserDefaults.standard.object(forKey: updateCheckEnabledKey) as? Bool
    }

    var intervalDays: Int? {
        UserDefaults.standard.object(forKey: updateCheckIntervalKey) as? Int
    }

    var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: lastCheckKey) }
    }
}
