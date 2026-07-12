#if DEBUG
import SwiftUI
import KomgaKit

/// TEMPORARY DEBUG harness (`-debugEpubReader`): opens the ePub at the host
/// path given in the EPUB_PATH environment variable through the real
/// EpubReaderContainer (image-only detection → image reader / Readium
/// fallback). Simulator builds can read host paths directly. Remove after use.
struct DebugEpubHarness: View {
    @State private var fileURL: URL?
    @State private var book: KomgaBook?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let fileURL, let book {
                    EpubReaderContainer(
                        book: book,
                        fileURL: fileURL,
                        client: nil,
                        initialPage: ProcessInfo.processInfo.environment["EPUB_PAGE"].flatMap(Int.init),
                        onProgress: { page, completed in
                            print("EPUB HARNESS progress page=\(page) completed=\(completed)")
                        }
                    )
                } else if failed {
                    Text("EPUB_PATH が不正です")
                } else {
                    ProgressView("準備中…")
                }
            }
        }
        .task { prepare() }
    }

    private func prepare() {
        guard
            let path = ProcessInfo.processInfo.environment["EPUB_PATH"],
            FileManager.default.fileExists(atPath: path)
        else {
            print("EPUB HARNESS ERROR: EPUB_PATH missing or not found")
            failed = true
            return
        }
        do {
            fileURL = URL(fileURLWithPath: path)
            book = try Self.stubBook()
        } catch {
            print("EPUB HARNESS ERROR: \(error)")
            failed = true
        }
    }

    private static func stubBook() throws -> KomgaBook {
        let json = """
        {"id":"HEPUB","seriesId":"HS","seriesTitle":"HS","libraryId":"HL","name":"h","url":"/tmp/h.epub","number":1,"sizeBytes":1,
        "media":{"status":"READY","mediaType":"application/epub+zip","pagesCount":0,"mediaProfile":"EPUB"},
        "metadata":{"title":"Harness EPUB","summary":"","number":"1","authors":[]}}
        """
        return try JSONDecoder().decode(KomgaBook.self, from: Data(json.utf8))
    }
}
#endif
