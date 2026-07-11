import Foundation

/// User-selectable disk-cache byte budget for ``PageImageLoader``'s page cache.
///
/// Persisted in `UserDefaults` under ``storageKey`` as its raw string (the byte
/// count). The Settings screen binds an `@AppStorage(CacheLimit.storageKey)`
/// property to the same key, and ``AppServices`` reads it when creating (and
/// updating) the loader.
enum CacheLimit: Int, CaseIterable, Identifiable, Sendable {
    case mb500 = 524_288_000       // 500 MB
    case gb1 = 1_073_741_824       // 1 GB
    case gb2 = 2_147_483_648       // 2 GB
    case gb4 = 4_294_967_296       // 4 GB

    var id: Int { rawValue }

    /// The `UserDefaults` key shared with the Settings screen's `@AppStorage`.
    /// The stored value is the raw byte count.
    static let storageKey = "pageCacheDiskLimitBytes"

    /// The default when nothing is stored (1 GB, matching design.md §5).
    static let defaultValue: CacheLimit = .gb1

    /// The persisted byte budget, falling back to ``defaultValue`` when unset or
    /// not one of the known options.
    static func currentBytes(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: storageKey)
        guard stored > 0, let value = CacheLimit(rawValue: stored) else {
            return defaultValue.rawValue
        }
        return value.rawValue
    }

    /// Japanese label for the picker.
    var label: String {
        switch self {
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        case .gb2: return "2 GB"
        case .gb4: return "4 GB"
        }
    }
}

/// User-selectable default reading direction, applied when neither the series
/// metadata nor a per-book override specifies one.
///
/// Persisted in `UserDefaults` under ``storageKey`` as its raw string. The
/// reader's initial-state resolution reads it as the final fallback.
enum ReadingDirectionDefault: String, CaseIterable, Identifiable, Sendable {
    /// Left-to-right (left-bound). Matches Komga's `LEFT_TO_RIGHT`.
    case leftToRight = "LEFT_TO_RIGHT"
    /// Right-to-left (right-bound, manga style). Matches Komga's `RIGHT_TO_LEFT`.
    case rightToLeft = "RIGHT_TO_LEFT"

    var id: String { rawValue }

    /// The `UserDefaults` key shared with the Settings screen's `@AppStorage`.
    static let storageKey = "defaultReadingDirection"

    /// The default when nothing is stored (LTR, matching design.md §2.3).
    static let defaultValue: ReadingDirectionDefault = .leftToRight

    /// Reads the persisted value, falling back to ``defaultValue``.
    static func current(_ defaults: UserDefaults = .standard) -> ReadingDirectionDefault {
        guard let raw = defaults.string(forKey: storageKey),
              let value = ReadingDirectionDefault(rawValue: raw) else {
            return defaultValue
        }
        return value
    }

    /// Japanese label for the picker.
    var label: String {
        switch self {
        case .leftToRight: return "左綴じ（右送り）"
        case .rightToLeft: return "右綴じ（左送り）"
        }
    }
}
