import Foundation
import KomgaKit

/// The horizontal reading progression used by the image reader.
///
/// `VERTICAL` / `WEBTOON` series are read with horizontal paging in this app
/// (vertical scrolling is out of scope), so they map to ``leftToRight``.
enum ReadingProgression: String, Sendable {
    /// Left-to-right (left-bound). Page turns advance to the *right*.
    case leftToRight = "LEFT_TO_RIGHT"
    /// Right-to-left (right-bound, manga style). Page turns advance to the *left*.
    case rightToLeft = "RIGHT_TO_LEFT"

    /// Whether pages advance toward the right edge (LTR) or left edge (RTL).
    var isRightToLeft: Bool { self == .rightToLeft }

    /// The opposite progression, for the in-reader toggle.
    var toggled: ReadingProgression {
        isRightToLeft ? .leftToRight : .rightToLeft
    }

    /// Japanese label describing the binding.
    var label: String {
        isRightToLeft ? "右綴じ（左送り）" : "左綴じ（右送り）"
    }

    /// Derives the initial progression from series metadata.
    ///
    /// Unset / unknown / vertical / webtoon all default to ``leftToRight`` per
    /// design.md §2.3.
    static func from(seriesDirection: KomgaReadingDirection) -> ReadingProgression {
        switch seriesDirection {
        case .rightToLeft: return .rightToLeft
        case .leftToRight, .vertical, .webtoon, .unknown: return .leftToRight
        }
    }

    /// Parses a persisted override string (from `LocalReadingState`), or `nil`.
    static func fromOverride(_ raw: String?) -> ReadingProgression? {
        guard let raw else { return nil }
        return ReadingProgression(rawValue: raw)
    }
}
