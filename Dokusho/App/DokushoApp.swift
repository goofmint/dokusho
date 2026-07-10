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
            ContentView()
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
                    // Push any queued read progress as soon as we're active again.
                    if phase == .active, let syncer = services.progressSyncer {
                        Task { await syncer.flushPending() }
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
