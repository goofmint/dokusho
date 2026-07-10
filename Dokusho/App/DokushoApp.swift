import SwiftUI
import SwiftData

@main
struct DokushoApp: App {
    /// Bridges UIKit app-delegate callbacks (background URLSession completion).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Single shared SwiftData container for the whole app.
    private let modelContainer = PersistenceController.makeContainer()

    /// Root dependency container injected into the environment.
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(services)
        }
        .modelContainer(modelContainer)
    }
}
