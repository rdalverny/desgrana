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
