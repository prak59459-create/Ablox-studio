import SwiftUI
import AbloxCore
import EditorCore

@main
struct AbloxStudioApp: App {
    @StateObject private var settings = StudioSettings()
    @StateObject private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ProjectBrowserView()
                .environmentObject(settings)
                .environmentObject(store)
        }
    }
}
