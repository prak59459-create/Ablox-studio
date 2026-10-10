import SwiftUI
import AbloxCore

/// The sound library as a picker: the chosen sound's name goes into a rule
/// or a script. Reads the library from the game list's repository and branch.
struct StudioSoundLibrarySheet: View {
    @EnvironmentObject private var settings: StudioSettings
    let onPick: (String) -> Void

    var body: some View {
        SoundLibraryView(source: settings.catalogueSource, onPick: onPick)
    }
}

/// Which rule action a library sound is being chosen for.
struct SoundPickTarget: Identifiable {
    let rule: UUID
    let index: Int
    var id: String { "\(rule.uuidString)-\(index)" }
}
