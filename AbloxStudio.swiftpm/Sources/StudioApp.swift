import SwiftUI
import AbloxCore

@main
struct AbloxStudioApp: App {
    @StateObject private var settings = StudioSettings()
    @StateObject private var store = ProjectStore()
    @StateObject private var updater = AppUpdater(release: AppRelease.current)
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything else: notices a crash last time and watches this run.
        ProblemRecorder.shared.start(app: "Ablox Studio")
        ProblemRecorder.shared.noteActivity("Starting")
    }

    var body: some Scene {
        WindowGroup {
            ProjectBrowserView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(updater)
                // Rebuilds the interface when the language changes.
                //
                // `L(...)` reads a global SwiftUI knows nothing about, so
                // nothing would redraw on its own. Changing the identity here
                // forces one rebuild — deliberately below the state objects,
                // so the open project and its undo history survive it.
                .id(settings.language)
                // Offers Ablox's own keyboard on an iPad where the system one
                // does not come up.
                .onAppear { KeyboardController.shared.startWatching() }
                // Going to the background is not a crash.
                .onChange(of: scenePhase) { _, phase in
                    ProblemRecorder.shared.markRunning(phase != .background)
                }
                .onChange(of: store.lastError) { _, error in
                    if let error { ProblemRecorder.shared.record(.saving, error) }
                }
        }
    }
}
