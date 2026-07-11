import Foundation

/// Parses the date-time strings Komga produces.
///
/// Komga (Jackson) serializes `LocalDateTime` **without** a timezone
/// designator and with a variable-length fractional part, e.g.
/// `2024-05-31T09:00:00`, `2024-05-31T09:00:00.123456`. Some fields may also
/// carry an explicit zone (`...Z` / `...+09:00`). This parser accepts all of
/// these; zone-less values are interpreted as UTC.
public enum KomgaDateParser {
    /// Parses a Komga date-time string. Returns `nil` when unrecognized.
    ///
    /// Formatters are created per call: neither `ISO8601DateFormatter` nor
    /// `DateFormatter` is `Sendable`, and this is called from a `@Sendable`
    /// decoding strategy.
    public static func parse(_ raw: String) -> Date? {
        let normalized = clampFraction(raw)

        // Zone-suffixed ISO-8601 first.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: normalized) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: normalized) {
            return date
        }

        // Zone-less LocalDateTime, interpreted as UTC.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: "UTC")
        local.dateFormat = normalized.contains(".")
            ? "yyyy-MM-dd'T'HH:mm:ss.SSS"
            : "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: normalized)
    }

    /// Clamps a fractional-seconds part to exactly 3 digits (padding with
    /// zeros, truncating extras) so both formatters can handle Komga's
    /// variable-length fractions. Strings without a fraction pass through.
    private static func clampFraction(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        let afterDot = string[string.index(after: dot)...]
        let digits = afterDot.prefix(while: \.isNumber)
        let suffix = afterDot[digits.endIndex...]
        let clamped = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return "\(string[..<dot]).\(clamped)\(suffix)"
    }
}
