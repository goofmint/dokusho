import SwiftUI
import Observation
import os
import KomgaKit

/// Logs home-row revalidation failures (cached data is kept, no error shown).
private let homeLogger = Logger(subsystem: "jp.moongift.dokusho", category: "BrowseHome")

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
                .onAppear {
                    // TabView keeps this view alive, so `.task` runs only once.
                    // Silently revalidate on every return so "読書中" reflects
                    // reading done elsewhere in the app. Guarded to `.loaded`, so
                    // the first appearance defers to `.task` (no double fetch).
                    Task { await viewModel.revalidateIfLoaded(client: services.client) }
                }
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

    private let cache = BrowseCache.shared
    private let keepReadingKey = "home-keepreading"
    private let onDeckKey = "home-ondeck"

    /// Guards against overlapping silent revalidations. `.onAppear` can fire in
    /// quick succession (and alongside the cache-hit revalidate in
    /// `loadIfNeeded`); a second revalidate while one is in flight would race
    /// the same row/cache writes. Single-flight on the main actor: the
    /// check-and-set has no `await` between them.
    @ObservationIgnored private var isRevalidating = false

    /// Monotonic id bumped at the start of every fetch (manual `reload` and
    /// silent `revalidate` alike). A fetch only applies its result if it is
    /// still the latest — so a slower fetch can never overwrite the rows/cache
    /// written by a fetch that started after it (e.g. a stale silent revalidate
    /// clobbering a manual pull-to-refresh).
    @ObservationIgnored private var fetchGeneration = 0

    /// On first appear, show the cached rows immediately, then revalidate over
    /// the network (replacing the rows and refreshing the cache on success;
    /// keeping cached data on failure).
    func loadIfNeeded(client: KomgaClient?) async {
        guard case .idle = phase else { return }

        let cachedKeep = await cache.load([KomgaBook].self, key: keepReadingKey)
        let cachedDeck = await cache.load([KomgaBook].self, key: onDeckKey)
        if let cachedKeep, let cachedDeck {
            keepReading = cachedKeep
            onDeck = cachedDeck
            phase = .loaded
            await revalidate(client: client)
        } else {
            await reload(client: client)
        }
    }

    /// Silently revalidates on a repeat appearance, but only once the initial
    /// load has finished successfully. Cached rows stay visible throughout; on
    /// success the rows and cache update, on failure the cached rows are kept.
    /// The `.loaded` guard makes the first appearance a no-op (``loadIfNeeded``
    /// via `.task` owns the first fetch), so the two never race a double fetch.
    func revalidateIfLoaded(client: KomgaClient?) async {
        guard case .loaded = phase else { return }
        await revalidate(client: client)
    }

    /// Forces a fresh fetch (pull-to-refresh / retry) and refreshes the cache.
    func reload(client: KomgaClient?) async {
        guard let client else {
            phase = .failed("サーバーに接続していません。")
            return
        }
        let previousPhase = phase
        phase = .loading
        do {
            try await fetchAndCache(client: client)
            phase = .loaded
        } catch is CancellationError {
            // Cancelled (view dismissed, or a newer refresh superseded this
            // one): don't strand the view on the spinner. Restore whatever was
            // showing before — cached content if we had it, else idle.
            phase = previousPhase == .loading ? .idle : previousPhase
        } catch {
            phase = .failed(ErrorMessage.text(for: error))
        }
    }

    /// Fetches without a spinner, keeping cached rows if the network fails.
    private func revalidate(client: KomgaClient?) async {
        guard let client else { return }
        // Single-flight: skip if a revalidation is already running.
        guard !isRevalidating else { return }
        isRevalidating = true
        defer { isRevalidating = false }
        let previousPhase = phase
        do {
            try await fetchAndCache(client: client)
            phase = .loaded
        } catch is CancellationError {
            // Revalidation runs after cached rows are already shown (.loaded);
            // restore that phase so the view is never left non-terminal.
            phase = previousPhase == .loading ? .idle : previousPhase
        } catch {
            // Keep showing cached rows; no error view when cache is present.
            homeLogger.error("Home revalidation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches both rows concurrently and writes each back to the cache.
    ///
    /// Tagged with a generation so a fetch that was superseded while awaiting
    /// the network drops its (older) result instead of overwriting the newer
    /// one — the writes are otherwise shared by `reload` and `revalidate`.
    private func fetchAndCache(client: KomgaClient) async throws {
        fetchGeneration &+= 1
        let generation = fetchGeneration
        async let keep = client.keepReading(page: 0, size: browsePageSize)
        async let deck = client.onDeck(page: 0, size: browsePageSize)
        let (keepPage, deckPage) = try await (keep, deck)
        // A newer fetch started while we were awaiting: its result supersedes
        // ours, so don't apply stale rows/cache over it.
        guard generation == fetchGeneration else { return }
        keepReading = keepPage.content
        onDeck = deckPage.content
        // Recheck before each disk write: a newer fetch can complete during a
        // save's `await`, so re-verify we're still latest to avoid persisting a
        // mixed-generation cache (keep from one fetch, on-deck from another).
        guard generation == fetchGeneration else { return }
        await cache.save(keepPage.content, key: keepReadingKey)
        guard generation == fetchGeneration else { return }
        await cache.save(deckPage.content, key: onDeckKey)
    }
}
