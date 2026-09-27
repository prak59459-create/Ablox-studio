import SwiftUI
import AbloxCore

// The world check, what the world is made of, and the building tools that
// need a few choices first: replacing a colour, scattering copies, naming
// parts in a row. Plus the selections and camera spots kept per world.

// MARK: - World check

struct WorldCheckSheet: View {
    @ObservedObject var session: StudioSession
    let commands: ViewportCommands
    @Environment(\.dismiss) private var dismiss
    @State private var cleaned: Int?

    var body: some View {
        let check = WorldCheck.run(session.document.world)
        NavigationStack {
            List {
                if check.isClean {
                    Label(L("Nothing to fix. Happy building!"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Ablox.Palette.success)
                }
                ForEach(check.findings) { finding in
                    row(finding)
                }
                if let cleaned {
                    Text(L("Removed {} parts.", cleaned))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
            }
            .navigationTitle(L("World check"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func row(_ finding: WorldCheck.Finding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(finding.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: Self.symbol(finding.level))
                    .foregroundStyle(Self.tint(finding.level))
            }
            HStack(spacing: 10) {
                if !finding.blocks.isEmpty {
                    Button(L("Select them")) { select(finding.blocks) }
                        .buttonStyle(NeonButtonStyle(.secondary))
                }
                if finding.id == "doubles" {
                    Button(L("Clean up")) {
                        var removed = 0
                        session.edit { removed = $0.removeDuplicates() }
                        cleaned = removed
                    }
                    .buttonStyle(NeonButtonStyle(.primary))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func select(_ ids: [UUID]) {
        session.edit { $0.selection = Set(ids) }
        commands.frame(session.document.selectionBounds)
        dismiss()
    }

    static func symbol(_ level: WorldCheck.Finding.Level) -> String {
        switch level {
        case .problem: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "info.circle.fill"
        }
    }

    static func tint(_ level: WorldCheck.Finding.Level) -> Color {
        switch level {
        case .problem: return Ablox.Palette.danger
        case .warning: return Ablox.Palette.warning
        case .note: return Ablox.Palette.accent
        }
    }
}

// MARK: - What the world is made of

struct WorldStatsSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let stats = WorldStatistics.of(session.document.world)
        NavigationStack {
            List {
                Section {
                    value(L("Parts"), "\(stats.parts)")
                    value(L("Groups"), "\(stats.groups)")
                    value(L("Size"), String(format: "%.0f × %.0f × %.0f m", stats.size.x, stats.size.y, stats.size.z))
                    value(L("Scripts"), L("{} files, {} lines", stats.scriptFiles, stats.scriptLines))
                    value(L("Pictures"), "\(stats.pictures)")
                }
                counts(L("Shapes"), stats.shapes)
                counts(L("Materials"), stats.materials)
                if !stats.behaviours.isEmpty { counts(L("What parts do"), stats.behaviours) }
                Section(L("Colours used most")) {
                    ForEach(stats.colours) { colour in
                        HStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(ColorRGBA(hex: colour.name) ?? ColorRGBA(r: 1, g: 1, b: 1)))
                                .frame(width: 22, height: 22)
                            Text(colour.name).font(.caption.monospaced())
                            Spacer()
                            Text("\(colour.count)").foregroundStyle(Ablox.Palette.inkMuted)
                        }
                    }
                }
            }
            .navigationTitle(L("What is in this world"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func value(_ name: String, _ text: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(text).foregroundStyle(Ablox.Palette.inkMuted)
        }
    }

    private func counts(_ title: String, _ list: [WorldStatistics.Count]) -> some View {
        Section(title) {
            ForEach(list) { item in value(item.name, "\(item.count)") }
        }
    }
}

// MARK: - Replacing a colour

struct ReplaceColourSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var from: ColorRGBA?
    @State private var to = ColorRGBA(hex: "#3B82F6")!
    @State private var result: Int?

    var body: some View {
        let inUse = Array(session.document.coloursInUse.prefix(24))
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.document.selection.isEmpty
                         ? L("Every part in the world with the first colour is painted the second.")
                         : L("Only the selected parts change."))
                        .font(.subheadline)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                    Text(L("Colour to replace")).font(.headline)
                    swatches(inUse, selected: from) { from = $0 }
                    Text(L("New colour")).font(.headline)
                    HStack {
                        ColorPicker(L("New colour"), selection: Binding(get: { Color(to) }, set: { to = Self.rgba($0) }),
                                    supportsOpacity: false)
                            .labelsHidden()
                        swatches(Array(ColorRGBA.palette.prefix(12)), selected: to) { to = $0 }
                    }
                    Button {
                        guard let from else { return }
                        var changed = 0
                        session.edit { changed = $0.replaceColour(from, with: to) }
                        result = changed
                    } label: {
                        Label(L("Replace"), systemImage: "paintbrush.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
                    .disabled(from == nil)
                    if let result {
                        Text(L("{} parts repainted.", result)).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
                    }
                }
                .padding(20)
            }
            .navigationTitle(L("Replace a colour"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func swatches(_ colours: [ColorRGBA], selected: ColorRGBA?, pick: @escaping (ColorRGBA) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)], spacing: 8) {
            ForEach(colours.indices, id: \.self) { index in
                ColorSwatch(color: colours[index], isSelected: selected.map { EditorDocument.sameColour($0, colours[index]) } ?? false,
                            size: 30) { pick(colours[index]) }
            }
        }
    }

    static func rgba(_ value: Color) -> ColorRGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
        return ColorRGBA(r: Float(r), g: Float(g), b: Float(b))
    }
}

// MARK: - Scattering and naming

struct ScatterSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var count = 12
    @State private var radius: Double = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Scatter copies")).font(.title3.weight(.bold))
            Text(L("Copies of the selection are dropped at random around it, each turned a different way: trees in a wood, rocks on a beach."))
                .font(.subheadline)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Stepper(L("{} copies", count), value: $count, in: 2...100)
            VStack(alignment: .leading) {
                Text(L("Within {} m", Int(radius)))
                Slider(value: $radius, in: 2...60, step: 1)
            }
            HStack {
                Button(L("Cancel")) { dismiss() }
                Spacer()
                Button(L("Scatter")) {
                    session.edit { $0.scatter(count: count, radius: Float(radius), seed: UInt64.random(in: 1...UInt64.max)) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(340)])
    }
}

struct RenameInOrderSheet: View {
    @ObservedObject var session: StudioSession
    @State private var base = ""

    var body: some View {
        TextPromptSheet(title: L("Name in order"),
                        message: L("The selected parts become “Name 1”, “Name 2”… from one end to the other, so a script can find each."),
                        placeholder: L("Coin"), confirm: L("Rename"), text: $base) {
            session.edit { $0.renameInOrder(base) }
        }
    }
}

// MARK: - Kept per world: selections and camera spots

/// Small things Studio remembers for each world, on this iPad only.
enum StudioMemory {
    static func load<T: Decodable>(_ type: T.Type, _ kind: String, world: UUID) -> T? {
        guard let data = UserDefaults.standard.data(forKey: "ablox.studio.\(kind).\(world.uuidString)") else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ kind: String, world: UUID) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: "ablox.studio.\(kind).\(world.uuidString)")
    }
}

/// The "…" menu's section for picking parts again and going back to places.
///
/// Read afresh each time the menu is drawn: views inside a menu get no
/// `onAppear`, so there is no state here, and `changed` asks the menu's
/// owner to draw it again after something is kept.
struct KeptPlacesMenu: View {
    @ObservedObject var session: StudioSession
    let commands: ViewportCommands
    @Binding var sheet: StudioSheet?
    /// Bumped by the owner after a change, so the menu is redrawn.
    let revision: Int
    let changed: () -> Void

    private var world: UUID { session.document.world.id }
    private var sets: SelectionSets { StudioMemory.load(SelectionSets.self, "selections", world: world) ?? SelectionSets() }
    private var spots: CameraBookmarks { StudioMemory.load(CameraBookmarks.self, "cameraSpots", world: world) ?? CameraBookmarks() }

    var body: some View {
        let sets = sets
        let spots = spots
        Menu {
            Button {
                sheet = .saveSelection
            } label: {
                Label(L("Keep this selection…"), systemImage: "square.and.arrow.down")
            }
            .disabled(session.document.selection.isEmpty)
            ForEach(sets.names, id: \.self) { name in
                Button {
                    let ids = sets.ids(name, in: session.document.world)
                    session.edit { $0.selection = ids }
                    commands.frame(session.document.selectionBounds)
                } label: {
                    Label(name, systemImage: "checklist")
                }
            }
            if !sets.names.isEmpty {
                Menu(L("Forget a selection")) {
                    ForEach(sets.names, id: \.self) { name in
                        Button(name, role: .destructive) {
                            var kept = sets
                            kept.remove(name)
                            StudioMemory.save(kept, "selections", world: world)
                            changed()
                        }
                    }
                }
            }
            Divider()
            ForEach(0..<CameraBookmarks.slots, id: \.self) { slot in
                Menu(L("Camera spot {}", slot + 1)) {
                    Button {
                        if let spot = commands.cameraSpot() {
                            var kept = spots
                            kept.save(spot, in: slot)
                            StudioMemory.save(kept, "cameraSpots", world: world)
                            changed()
                        }
                    } label: {
                        Label(L("Keep the view here"), systemImage: "camera.viewfinder")
                    }
                    if let spot = spots.spot(slot) {
                        Button {
                            commands.go(to: spot)
                        } label: {
                            Label(L("Go there"), systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
        } label: {
            Label(L("Kept selections and views"), systemImage: "bookmark.fill")
        }
        .id(revision)
    }
}

struct SaveSelectionSheet: View {
    @ObservedObject var session: StudioSession
    @State private var name = ""

    var body: some View {
        TextPromptSheet(title: L("Keep this selection"),
                        message: L("Pick the same parts again later from the … menu."),
                        placeholder: L("Coins on level 2"), confirm: L("Keep"), text: $name) {
            let world = session.document.world.id
            var sets = StudioMemory.load(SelectionSets.self, "selections", world: world) ?? SelectionSets()
            if sets.save(name, ids: session.document.selection) {
                StudioMemory.save(sets, "selections", world: world)
            }
        }
    }
}
