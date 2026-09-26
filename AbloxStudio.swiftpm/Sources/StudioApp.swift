import SwiftUI

@main
struct AbloxStudioApp: App {
    @StateObject private var settings = StudioSettings()
    @StateObject private var store = ProjectStore()
    @StateObject private var updater = AppUpdater(release: AppRelease.current)

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
        }
    }
}
