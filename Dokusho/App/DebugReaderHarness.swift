#if DEBUG
import SwiftUI
import UIKit
import KomgaKit

/// DEBUG-only harness: launch the app with `-debugPdfReader` to open the image
/// reader directly on a locally generated multi-page PDF, with no server or
/// connection required. Used to verify reader interactions (tap zones, HUD,
/// spreads, direction toggle) in the simulator via automated taps.
struct DebugReaderHarness: View {
    @State private var source: LocalPdfPageSource?
    @State private var book: KomgaBook?

    var body: some View {
        NavigationStack {
            Group {
                if let source, let book {
                    ImageReaderScreen(
                        book: book,
                        source: source,
                        client: nil,
                        onProgress: { page, completed in
                            print("HARNESS PROGRESS page=\(page) completed=\(completed)")
                        }
                    )
                } else {
                    ProgressView("ハーネス準備中…")
                }
            }
        }
        .task {
            prepare()
        }
    }

    private func prepare() {
        do {
            let url = try Self.generatePDF(pageCount: 6)
            guard let pdfSource = LocalPdfPageSource(fileURL: url) else {
                print("HARNESS ERROR: LocalPdfPageSource failed to open")
                return
            }
            source = pdfSource
            book = try Self.stubBook()
        } catch {
            print("HARNESS ERROR: \(error)")
        }
    }

    /// Renders a simple numbered PDF so pages are visually distinguishable.
    private static func generatePDF(pageCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness.pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 600, height: 900)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let colors: [UIColor] = [
            .systemRed, .systemBlue, .systemGreen,
            .systemOrange, .systemPurple, .systemTeal,
        ]
        let data = renderer.pdfData { context in
            for page in 1...pageCount {
                context.beginPage()
                colors[(page - 1) % colors.count].setFill()
                context.fill(pageRect)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 220, weight: .black),
                    .foregroundColor: UIColor.white,
                ]
                let text = "\(page)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(
                    at: CGPoint(
                        x: (pageRect.width - size.width) / 2,
                        y: (pageRect.height - size.height) / 2
                    ),
                    withAttributes: attributes
                )
            }
        }
        try data.write(to: url)
        return url
    }

    /// Builds a minimal KomgaBook via its Decodable conformance (it has no
    /// public memberwise initializer).
    private static func stubBook() throws -> KomgaBook {
        let json = """
        {
          "id": "HARNESS01",
          "seriesId": "HARNESSSERIES",
          "seriesTitle": "Harness Series",
          "libraryId": "HARNESSLIB",
          "name": "harness",
          "url": "/tmp/harness.pdf",
          "number": 1,
          "sizeBytes": 1000,
          "media": { "status": "READY", "mediaType": "application/pdf", "pagesCount": 6, "mediaProfile": "PDF" },
          "metadata": { "title": "Harness PDF", "summary": "", "number": "1", "authors": [] }
        }
        """
        return try JSONDecoder().decode(KomgaBook.self, from: Data(json.utf8))
    }
}
#endif
