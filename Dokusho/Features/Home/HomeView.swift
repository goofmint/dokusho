import SwiftUI
import Observation
import KomgaKit

/// The home screen: "Keep Reading" (読書中) and "On Deck" (次に読む) horizontal
/// rows. Tapping a book pushes ``BrowseRoute/book(_:)`` (continue-from goes
/// through the book detail for now).
struct HomeView: View {
    @Environment(AppServices.self) private var services
    @State private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ホーム")
                .browseDestinations()
                .task { await viewModel.loadIfNeeded(client: services.client) }
                .refreshable { await viewModel.reload(client: services.client) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case let .failed(message):
            ErrorStateView(message: message) {
                Task { await viewModel.reload(client: services.client) }
            }
        case .loaded:
            if viewModel.keepReading.isEmpty && viewModel.onDeck.isEmpty {
                ContentUnavailableView(
                    "読書中の本はありません",
                    systemImage: "house",
                    description: Text("ライブラリから本を開くとここに表示されます。")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !viewModel.keepReading.isEmpty {
                            HomeBookRow(title: "読書中", books: viewModel.keepReading)
                        }
                        if !viewModel.onDeck.isEmpty {
                            HomeBookRow(title: "次に読む", books: viewModel.onDeck)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
    }
}

/// A titled, horizontally scrolling row of book covers.
private struct HomeBookRow: View {
    let title: String
    let books: [KomgaBook]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(books) { book in
                        NavigationLink(value: BrowseRoute.book(book)) {
                            HomeBookCell(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// A single home-row cover cell with title and progress.
private struct HomeBookCell: View {
    let book: KomgaBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImageView(target: .book(id: book.id))
                .aspectRatio(0.7, contentMode: .fit)
                .frame(width: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(book.metadata.title.isEmpty ? book.name : book.metadata.title)
                .font(.caption)
                .lineLimit(2)
            BookProgressLabel(book: book)
        }
        .frame(width: 120)
    }
}

/// Loads the two home rows (Keep Reading, On Deck) concurrently.
@MainActor
@Observable
final class HomeViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var keepReading: [KomgaBook] = []
    private(set) var onDeck: [KomgaBook] = []
    private(set) var phase: Phase = .idle

    func loadIfNeeded(client: KomgaClient?) async {
        guard case .idle = phase else { return }
        await reload(client: client)
    }

    func reload(client: KomgaClient?) async {
        guard let client else {
            phase = .failed("サーバーに接続していません。")
            return
        }
        phase = .loading
        do {
            async let keep = client.keepReading(page: 0, size: browsePageSize)
            async let deck = client.onDeck(page: 0, size: browsePageSize)
            let (keepPage, deckPage) = try await (keep, deck)
            keepReading = keepPage.content
            onDeck = deckPage.content
            phase = .loaded
        } catch is CancellationError {
        } catch {
            phase = .failed(ErrorMessage.text(for: error))
        }
    }
}
