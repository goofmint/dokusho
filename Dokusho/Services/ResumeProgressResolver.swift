import Foundation

/// Outcome of comparing local reading progress with the server snapshot.
///
/// Local progress is the default whenever it exists. A ``conflict`` is reported
/// only when both sides have a page, the pages differ, and the server
/// `readDate` is strictly newer than the local `updatedAt`.
enum ResumeProgressResult: Equatable, Sendable {
    /// No confirmation needed. `page` is `nil` when neither side has progress.
    case aligned(page: Int?)
    /// Cloud is newer and the pages differ. The default adoption is `localPage`.
    case conflict(localPage: Int, cloudPage: Int)

    /// Page the reader should open unless the user explicitly picks the cloud.
    var adoptedPage: Int? {
        switch self {
        case .aligned(let page):
            return page
        case .conflict(let localPage, _):
            return localPage
        }
    }
}

/// Pure resume-page resolver. Local state wins; SwiftData and UI stay out.
///
/// Inputs are the local `page` / `updatedAt` and the server `page` / `readDate`.
/// Callers fetch those values; this type only applies the comparison rules.
enum ResumeProgressResolver {
    /// Resolves the 1-based resume page and whether the user must confirm a move.
    static func resolve(
        localPage: Int?,
        localUpdatedAt: Date?,
        serverPage: Int?,
        serverReadDate: Date?
    ) -> ResumeProgressResult {
        switch (localPage, serverPage) {
        case (nil, nil):
            return .aligned(page: nil)
        case (nil, let server?):
            return .aligned(page: server)
        case (let local?, nil):
            return .aligned(page: local)
        case (let local?, let server?) where local == server:
            return .aligned(page: local)
        case (let local?, let server?):
            if let serverReadDate, let localUpdatedAt, serverReadDate > localUpdatedAt {
                return .conflict(localPage: local, cloudPage: server)
            }
            return .aligned(page: local)
        }
    }
}
