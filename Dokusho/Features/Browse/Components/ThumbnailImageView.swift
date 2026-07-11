import SwiftUI
import KomgaKit

/// Asynchronously loads and displays a resource thumbnail through the shared
/// ``PageImageLoader``, with placeholder and failure states.
///
/// Reused by every grid cell and list row that shows cover art. The image is
/// loaded on appear and the task is cancelled on disappear.
struct ThumbnailImageView: View {
    let target: ThumbnailTarget

    @Environment(AppServices.self) private var services

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFail {
                placeholder(systemImage: "photo")
            } else {
                placeholder(systemImage: nil)
            }
        }
        .clipped()
        .task(id: target) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private func placeholder(systemImage: String?) -> some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.tertiary)
                        .font(.title2)
                } else {
                    ProgressView()
                }
            }
    }

    private func loadThumbnail() async {
        guard let loader = services.imageLoader else { return }
        didFail = false
        image = nil
        do {
            let loaded = try await loader.thumbnail(for: target)
            image = loaded
        } catch is CancellationError {
            // View disappeared; ignore.
        } catch {
            didFail = true
        }
    }
}
