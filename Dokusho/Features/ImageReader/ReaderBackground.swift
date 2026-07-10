import SwiftUI

/// User-selectable reader background color.
///
/// Persisted in `UserDefaults` under ``storageKey`` as its raw string. The
/// Settings screen (wired later) can bind an `@AppStorage(ReaderBackground.storageKey)`
/// property to the same key.
enum ReaderBackground: String, CaseIterable, Identifiable, Sendable {
    /// Solid black — the default for immersive reading.
    case black
    /// Solid white.
    case white
    /// Follows the system light/dark appearance.
    case system

    var id: String { rawValue }

    /// The `UserDefaults` key shared with the Settings screen's `@AppStorage`.
    static let storageKey = "readerBackground"

    /// The default when nothing is stored.
    static let defaultValue: ReaderBackground = .black

    /// Reads the persisted value, falling back to ``defaultValue``.
    static func current(_ defaults: UserDefaults = .standard) -> ReaderBackground {
        guard let raw = defaults.string(forKey: storageKey),
              let value = ReaderBackground(rawValue: raw) else {
            return defaultValue
        }
        return value
    }

    /// Japanese label for pickers.
    var label: String {
        switch self {
        case .black: return "黒"
        case .white: return "白"
        case .system: return "システム連動"
        }
    }

    /// The concrete UIKit color for the reader canvas.
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .white: return .white
        case .system: return .systemBackground
        }
    }

    /// Whether HUD content should be tinted for a light background.
    var prefersDarkForeground: Bool {
        switch self {
        case .black: return false
        case .white: return true
        case .system: return false // resolved dynamically by the system in views
        }
    }
}
