import SwiftUI

// The building tools' screens: the menu of extras over the 3D view, the bar
// for the tool in hand (paint, ground, box), the part library, the history,
// how heavy the world is, the builders' chat, and a test run from here.

// MARK: - Extras menu

struct StudioActionsMenu: View {
    @ObservedObject var session: StudioSession
    let commands: ViewportCommands
    @Binding var sheet: StudioSheet?

    @AppStorage(StudioSession.autosaveKey) private var autosaveSeconds: Double = 3
    @AppStorage("ablox.studio.dragSensitivity") private var dragSensitivity: Double = 1

    var body: some View {
        Menu {
            Section {
                Button {
                    session.copySelection()
                } label: {
                    Label(L("Copy"), systemImage: "doc.on.doc")
                }
                .disabled(session.document.selection.isEmpty)
                Button {
                    session.paste(at: commands.insertionPoint())
                } label: {
                    Label(L("Paste"), systemImage: "doc.on.clipboard")
                }
                Button {
                    sheet = .library
                } label: {
                    Label(L("Part library"), systemImage: "square.grid.2x2.fill")
                }
                Button {
                    sheet = .remakeArea
                } label: {
                    Label(L("Remake this area with AI"), systemImage: "wand.and.stars")
                }
                .disabled(session.document.selection.isEmpty)
            }
            Section {
                Menu {
                    ForEach(ViewAngle.allCases) { angle in
                        Button {
                            commands.setView(angle)
                        } label: {
                            Label(angle.displayName, systemImage: angle.symbolName)
                        }
                    }
                } label: {
                    Label(L("Camera"), systemImage: "video.fill")
                }
                Button {
                    sheet = .history
                } label: {
                    Label(L("Edit history"), systemImage: "clock.arrow.circlepath")
                }
                Button {
                    sheet = .weight
                } label: {
                    Label(L("How heavy is this world?"), systemImage: "scalemass.fill")
                }
                Button {
                    sheet = .testHere(commands.focusPoint())
                } label: {
                    Label(L("Test from here"), systemImage: "play.circle")
                }
                if session.isHosting || !session.collaborators.isEmpty {
                    Button {
                        sheet = .chat
                    } label: {
                        Label(L("Builders' chat"), systemImage: "bubble.left.and.bubble.right.fill")
                    }
                }
            }
            Section(L("Settings")) {
                Picker(L("Autosave"), selection: $autosaveSeconds) {
                    Text(L("A moment after each change")).tag(3.0)
                    Text(L("Every 30 seconds")).tag(30.0)
                    Text(L("Every minute")).tag(60.0)
                    Text(L("Every 5 minutes")).tag(300.0)
                    Text(L("Only when I save")).tag(0.0)
                }
                Picker(L("Drag speed"), selection: $dragSensitivity) {
                    Text(L("Slow and careful")).tag(0.4)
                    Text(L("Normal")).tag(1.0)
                    Text(L("Fast")).tag(2.0)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title2)
                .foregroundStyle(Ablox.Palette.accent)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .accessibilityLabel(L("More"))
    }
}

/// The sheets the extras open.
enum StudioSheet: Identifiable {
    case library, history, weight, chat, remakeArea
    case testHere(Vec3)

    var id: String {
        switch self {
        case .library: return "library"
        case .history: return "history"
        case .weight: return "weight"
        case .chat: return "chat"
        case .remakeArea: return "remake"
        case .testHere: return "test"
        }
    }
}

// MARK: - The tool in hand

/// Over the 3D view while painting, shaping the ground or drawing a box.
struct ToolOptionsBar: View {
    @ObservedObject var session: StudioSession
    @State private var generating = false

    var body: some View {
        HStack(spacing: 10) {
            switch session.document.tool {
            case .paint, .eyedropper:
                Image(systemName: session.document.tool.symbolName)
                ColorPicker(L("Colour"), selection: Binding(
                    get: { color(session.document.paintColor) },
                    set: { session.setPaintColor(rgba($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                ForEach(Array((session.document.recentColors + ColorRGBA.palette).prefix(12).enumerated()), id: \.offset) { _, swatch in
                    ColorSwatch(color: swatch, isSelected: swatch == session.document.paintColor, size: 24) {
                        session.setPaintColor(swatch)
                    }
                }
                Text(session.document.tool == .paint ? L("Tap or drag over parts to paint them.") : L("Tap a part to take its colour."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
            case .terrain:
                ForEach(TerrainAction.allCases) { action in
                    Button {
                        session.setTerrain(action)
                    } label: {
                        Label(action.displayName, systemImage: action.symbolName)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(NeonButtonStyle(session.document.terrainAction == action ? .primary : .secondary))
                }
                Stepper(L("Brush {}", session.document.terrainBrush), value: Binding(
                    get: { session.document.terrainBrush },
                    set: { session.setTerrain(brush: $0) }
                ), in: 1...4)
                .font(.caption)
                .fixedSize()
                Button {
                    generating = true
                } label: {
                    Label(L("Make hills"), systemImage: "mountain.2")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(NeonButtonStyle(.secondary))
                .confirmationDialog(L("Make rolling hills?"), isPresented: $generating, titleVisibility: .visible) {
                    ForEach([12, 20, 30], id: \.self) { size in
                        Button(L("{} × {} metres", size * 2, size * 2)) {
                            session.edit { $0.generateTerrain(size: size, height: 5, seed: UInt64.random(in: 1...1_000_000)) }
                        }
                    }
                    Button(L("Cancel"), role: .cancel) {}
                }
            case .boxSelect:
                Image(systemName: "rectangle.dashed")
                Text(L("Draw a box with one finger to pick every part inside it."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
            case .select, .move, .rotate, .scale:
                EmptyView()
            }
        }
        .foregroundStyle(Ablox.Palette.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func color(_ value: ColorRGBA) -> Color {
        Color(red: Double(value.r), green: Double(value.g), blue: Double(value.b))
    }

    private func rgba(_ value: Color) -> ColorRGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
        return ColorRGBA(r: Float(r), g: Float(g), b: Float(b))
    }
}

// MARK: - The part library

/// Parts saved by the player, kept on this iPad for every world.
enum PrefabStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Prefabs", isDirectory: true)
    }

    static func all() -> [Prefab] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Prefab.self, from: $0) }
        }
        .sorted { $0.name < $1.name }
    }

    static func save(_ prefab: Prefab) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(prefab) else { return }
        try? data.write(to: directory.appendingPathComponent(prefab.id.uuidString + ".json"), options: .atomic)
    }

    static func delete(_ prefab: Prefab) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(prefab.id.uuidString + ".json"))
    }
}

struct PartLibrarySheet: View {
    @ObservedObject var session: StudioSession
    let insertionPoint: () -> Vec3
    @Environment(\.dismiss) private var dismiss

    @State private var custom: [Prefab] = PrefabStore.all()
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !session.document.selection.isEmpty {
                        Button {
                            newName = session.document.primarySelection?.name ?? L("My part")
                            naming = true
                        } label: {
                            Label(L("Save the selection to my library"), systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
                    }
                    if !custom.isEmpty {
                        Text(L("Mine")).font(.headline)
                        grid(custom)
                    }
                    Text(L("Ready-made")).font(.headline)
                    grid(PrefabLibrary.builtIn)
                }
                .padding(18)
            }
            .navigationTitle(L("Part library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $naming) {
            TextPromptSheet(title: L("Name this part"), placeholder: L("Name"), confirm: L("Save"), text: $newName) {
                guard let clip = session.document.copySelection() else { return }
                PrefabStore.save(Prefab(name: newName, symbolName: "star.fill", blocks: clip.blocks, isCustom: true))
                custom = PrefabStore.all()
            }
        }
    }

    private func grid(_ prefabs: [Prefab]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
            ForEach(prefabs) { prefab in
                Button {
                    session.insert(prefab, at: insertionPoint())
                    dismiss()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: prefab.symbolName).font(.title)
                        Text(prefab.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(L("{} parts", prefab.blocks.count)).font(.caption2).foregroundStyle(Ablox.Palette.inkFaint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if prefab.isCustom {
                        Button(role: .destructive) {
                            PrefabStore.delete(prefab)
                            custom = PrefabStore.all()
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - History

struct HistorySheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let steps = session.document.historySteps
                if steps.isEmpty {
                    Text(L("Nothing to undo yet."))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
                ForEach(Array(steps.enumerated().reversed()), id: \.offset) { index, label in
                    Button {
                        session.edit { $0.undo(toStep: index) }
                    } label: {
                        HStack {
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Ablox.Palette.inkFaint)
                            Text(label)
                            Spacer()
                            Image(systemName: "arrow.uturn.backward").foregroundStyle(Ablox.Palette.inkFaint)
                        }
                    }
                }
            }
            .navigationTitle(L("Edit history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text(L("Tap a step to go back to just before it. Redo brings the steps back."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .padding()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - How heavy

struct WeightView: View {
    let weight: WorldWeight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("How heavy")).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
                Spacer()
                Badge(weight.level.displayName, color: color, systemImage: "scalemass.fill")
            }
            Text(L("{} parts · {} lines of script", weight.blocks, weight.scriptLines))
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
            ForEach(weight.advice, id: \.self) { line in
                Label(line, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var color: Color {
        switch weight.level {
        case .light, .fine: return Ablox.Palette.success
        case .heavy: return Ablox.Palette.warning
        case .tooHeavy: return Ablox.Palette.danger
        }
    }
}

struct WeightSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                WeightView(weight: WorldWeight.assess(session.document.world)).padding(20)
            }
            .navigationTitle(L("How heavy is this world?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}

// MARK: - The builders' chat

struct BuildersChatSheet: View {
    @ObservedObject var session: StudioSession
    let focusPoint: () -> Vec3
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(session.chat) { line in
                            HStack(alignment: .top) {
                                Text(line.name).font(.caption.weight(.bold))
                                    .foregroundStyle(line.isMine ? Ablox.Palette.accent : Ablox.Palette.warning)
                                Text(line.text).font(.subheadline)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    AbloxTextField(L("Message"), text: $draft, limit: 200) { send() }
                        .padding(10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        session.sendPin(at: focusPoint())
                    } label: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                    .accessibilityLabel(L("Point everyone here"))
                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(NeonButtonStyle(.primary))
                    .accessibilityLabel(L("Send"))
                }
                .padding(16)
            }
            .navigationTitle(L("Builders' chat"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func send() {
        session.sendChat(draft)
        draft = ""
    }
}

// MARK: - Test from here

struct TestHereSheet: View {
    let world: WorldDocument
    let start: Vec3
    @Environment(\.dismiss) private var dismiss
    @State private var report: ScriptTestReport?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let report {
                        TestReportView(report: report)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(18)
            }
            .navigationTitle(L("Test from here"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let world = self.world
            let start = self.start
            report = await Task.detached { GameRuntime.testRun(world: world, seconds: 10, robots: true, start: start + Vec3(0, 1, 0)) }.value
        }
    }
}

/// A test run's results: problems, what the players got, the robots, the
/// breakpoints and the heaviest handlers.
/// Which lines of a test run's log to show.
enum LogFilter: String, CaseIterable, Identifiable {
    case all, problems, output
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return L("All")
        case .problems: return L("Problems")
        case .output: return L("Output")
        }
    }
}

struct TestReportView: View {
    let report: ScriptTestReport
    var filter: LogFilter = .all
    /// Only lines with this in them (any capitals).
    var search = ""
    /// Tapping a problem, to go to its line.
    var onProblem: ((ScriptError) -> Void)?

    private func shows(_ text: String) -> Bool {
        let words = search.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || text.localizedCaseInsensitiveContains(words)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.isClean, filter != .output, search.isEmpty {
                Label(L("No problems found"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Ablox.Palette.success)
                    .font(.subheadline.weight(.semibold))
            }
            if filter != .output {
                ForEach(Array(report.problems.filter { shows($0.description) }.enumerated()), id: \.offset) { _, problem in
                    ProblemRow(problem: problem, onTap: onProblem)
                }
            }
            if filter != .problems {
                ForEach(Array((report.robotNotes + report.notes).filter(shows).enumerated()), id: \.offset) { _, note in
                    Text(verbatim: "• " + note).font(.footnote)
                }
                ForEach(Array(report.output.filter(shows).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: "> " + line)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Ablox.Palette.accent)
                }
            }
            if filter == .all, !report.hits.isEmpty {
                Text(L("Breakpoints")).font(.caption.weight(.bold)).padding(.top, 6)
                ForEach(Array(report.hits.enumerated()), id: \.offset) { _, hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("{} line {} at {} s", hit.file, hit.line, ScriptValue.format((hit.time * 10).rounded() / 10)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Ablox.Palette.warning)
                        ForEach(hit.variables, id: \.self) { variable in
                            Text(verbatim: "  \(variable.name) = \(variable.value)")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            if filter == .all, !report.costs.isEmpty {
                Text(L("Heaviest handlers")).font(.caption.weight(.bold)).padding(.top, 6)
                ForEach(report.costs.prefix(6)) { cost in
                    HStack {
                        Text(verbatim: cost.name).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(L("{}×, {} ms", cost.calls, ScriptValue.format((cost.seconds * 10_000).rounded() / 10)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Ablox.Palette.inkMuted)
                    }
                }
            }
        }
    }
}

// MARK: - Remaking an area with AI

/// Map AI for one piece of the world: the ground under the selected parts
/// is described to the assistant, with the parts around it, and what comes
/// back replaces only the selection.
struct MapAreaSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss

    @State private var request = MapPrompt.Request(size: .small)
    @State private var area: MapArea?
    @State private var answer = ""
    @State private var copied = false
    @State private var result: MapAreaResult?

    private var prompt: String {
        guard let area else { return "" }
        return MapPrompt.text(for: request, area: area, around: session.document.parts(around: area))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let area {
                    Section {
                        Label(L("{} × {} m, the ground under {} selected parts", ScriptValue.format(Double((area.width * 10).rounded() / 10)),
                                ScriptValue.format(Double((area.depth * 10).rounded() / 10)), session.document.selection.count),
                              systemImage: "square.dashed")
                        AbloxTextField(L("What goes here? (a pond, a maze, a market…)"), text: $request.theme)
                        Picker(L("Difficulty"), selection: $request.difficulty) {
                            ForEach(MapPrompt.Difficulty.allCases) { difficulty in
                                Text(difficulty.displayName).tag(difficulty)
                            }
                        }
                        Toggle(L("Coins"), isOn: $request.includeCoins)
                        Toggle(L("Hazards"), isOn: $request.includeHazards)
                    } footer: {
                        Text(L("Only the selected parts are replaced. Everything else in the world stays."))
                    }
                    Section(L("1. Copy the prompt")) {
                        Button {
                            UIPasteboard.general.string = prompt
                            copied = true
                        } label: {
                            Label(copied ? L("Copied") : L("Copy the prompt"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    Section(L("2. Paste the answer")) {
                        AbloxTextEditor(L("Paste the JSON the assistant replied with"), text: $answer, fontSize: 11)
                            .frame(height: 120)
                        Button {
                            build(in: area)
                        } label: {
                            Label(L("Build it here"), systemImage: "hammer.fill")
                        }
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let result {
                        Section {
                            if result.didChange {
                                Label(L("Replaced {} parts with {}.", result.removed, result.added), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Ablox.Palette.success)
                            }
                            if result.leftOut > 0 {
                                Text(L("{} parts were outside the area and were left out.", result.leftOut))
                                    .foregroundStyle(Ablox.Palette.warning)
                            }
                            ForEach(Array(result.problems.enumerated()), id: \.offset) { _, problem in
                                Text(verbatim: "• " + problem.description)
                                    .font(.caption)
                                    .foregroundStyle(Ablox.Palette.warning)
                            }
                            if !result.problems.isEmpty {
                                Button {
                                    UIPasteboard.general.string = MapPrompt.correction(for: result.problems)
                                } label: {
                                    Label(L("Copy what to fix"), systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                } else {
                    Text(L("Select the parts to remake first. The area is the ground under them."))
                }
            }
            .navigationTitle(L("Remake this area with AI"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { area = session.document.selectedArea }
        .onChange(of: request) { _, _ in copied = false }
    }

    private func build(in area: MapArea) {
        switch MapPlan.decode(from: answer) {
        case let .failure(problem):
            result = MapAreaResult(problems: [problem])
        case let .success(plan):
            var outcome = MapAreaResult()
            session.edit { outcome = $0.remakeSelection(with: plan, in: area) }
            result = outcome
        }
    }
}
