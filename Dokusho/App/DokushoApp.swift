import SwiftUI
import SwiftData

@main
struct DokushoApp: App {
    /// Bridges UIKit app-delegate callbacks (background URLSession completion).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Single shared SwiftData container for the whole app.
    private let modelContainer: ModelContainer

    /// Root dependency container injected into the environment.
    @State private var services: AppServices

    init() {
        let container = PersistenceController.makeContainer()
        modelContainer = container
        _services = State(initialValue: AppServices(modelContext: container.mainContext))
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(services)
                .onAppear {
                    appDelegate.downloadManager = services.downloadManager
                }
                .onChange(of: services.isConnected) {
                    // Rewire whenever the connection (and thus the manager) changes
                    // so buffered background-session events can flush.
                    appDelegate.downloadManager = services.downloadManager
                }
                .onChange(of: scenePhase) { _, phase in
                    guard let syncer = services.progressSyncer else { return }
                    switch phase {
                    case .active:
                        // Replay any previously-failed sends now that we're back.
                        Task { await syncer.flushPending() }
                    case .background:
                        // Leaving the app can strand a page still inside its
                        // debounce window; push it before we're suspended. Use
                        // `.background` (not `.inactive`) to avoid double-firing
                        // on transient inactive states like Control Center.
                        Task { await syncer.flushOutstanding() }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
        .modelContainer(modelContainer)
    }

    /// DEBUG builds can bypass the connection flow to test the reader directly.
    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if CommandLine.arguments.contains("-debugPdfReader") {
            DebugReaderHarness()
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}
