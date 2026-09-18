import SwiftUI

/// Properties of whatever is selected.
struct InspectorPanel: View {
    @ObservedObject var session: StudioSession

    private var selected: [BlockData] { session.document.selectedBlocks }

    var body: some View {
        VStack(spacing: 0) {
            header

            if selected.isEmpty {
                ScrollView { environmentSection.padding(14) }
            } else if selected.count > 1 {
                ScrollView { multiSelectionBody.padding(14) }
            } else {
                ScrollView { singleSelectionBody(selected[0]).padding(14) }
            }
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Label(headerTitle, systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Ablox.Palette.ink)
            Spacer()
            if !selected.isEmpty {
                Button {
                    session.deleteSelection()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.danger)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerTitle: String {
        switch selected.count {
        case 0: return "World"
        case 1: return "Part"
        default: return "\(selected.count) parts"
        }
    }

    // MARK: Single selection

    @ViewBuilder
    private func singleSelectionBody(_ block: BlockData) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            nameField(block)
            transformSection(block)
            appearanceSection(block)
            behaviorSection(block)
            flagsSection(block)
            tagsSection(block)
        }
    }

    private func nameField(_ block: BlockData) -> some View {
        InspectorGroup("Name") {
            TextField("Part", text: Binding(
                get: { block.name },
                set: { newValue in
                    session.edit { $0.mutateSelection(label: "Rename") { $0.name = newValue } }
                }
            ))
            .textFieldStyle(.plain)
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func transformSection(_ block: BlockData) -> some View {
        InspectorGroup("Transform") {
            VStack(spacing: 9) {
                vectorField("Position", value: block.position, step: 0.5) { newValue in
                    session.edit { $0.mutateSelection(label: "Move") { $0.position = newValue } }
                }
                vectorField("Rotation", value: block.rotationDegrees, step: 15, unit: "°") { newValue in
                    session.edit { $0.mutateSelection(label: "Rotate") { $0.rotationDegrees = newValue } }
                }
                vectorField("Size", value: block.scale, step: 0.5, minimum: 0.05) { newValue in
                    session.edit { $0.mutateSelection(label: "Resize") { $0.scale = newValue } }
                }
            }
        }
    }

    private func appearanceSection(_ block: BlockData) -> some View {
        InspectorGroup("Appearance") {
            VStack(alignment: .leading, spacing: 11) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 7)], spacing: 7) {
                    ForEach(ColorRGBA.palette, id: \.hexString) { color in
                        ColorSwatch(color: color, isSelected: block.color == color, size: 28) {
                            session.edit { $0.mutateSelection(label: "Recolour") { $0.color = color } }
                        }
                    }
                }

                labelledPicker("Shape", selection: Binding(
                    get: { block.shape },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change shape") { $0.shape = newValue } }
                    }
                ), options: BlockShape.allCases) { $0.displayName }

                labelledPicker("Material", selection: Binding(
                    get: { block.material },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change material") { $0.material = newValue } }
                    }
                ), options: MaterialKind.allCases) { $0.displayName }
            }
        }
    }

    private func behaviorSection(_ block: BlockData) -> some View {
        InspectorGroup("Behaviour") {
            VStack(alignment: .leading, spacing: 9) {
                labelledPicker("Acts as", selection: Binding(
                    get: { block.behavior },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change behaviour") { $0.behavior = newValue } }
                    }
                ), options: BlockBehavior.allCases) { $0.displayName }

                // Only collectibles and hazards do anything with a score, so
                // the field appears only when it means something.
                if block.behavior == .collectible || block.behavior == .hazard {
                    HStack {
                        Text(block.behavior == .collectible ? "Points" : "Penalty")
                            .font(.caption2)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                        Spacer()
                        Stepper(value: Binding(
                            get: { block.scoreValue },
                            set: { newValue in
                                session.edit { $0.mutateSelection(label: "Change points") { $0.scoreValue = newValue } }
                            }
                        ), in: 0...500, step: 5) {
                            Text("\(block.scoreValue)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Ablox.Palette.accent)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                if block.behavior != .none {
                    Text(behaviorHint(block.behavior))
                        .font(.system(size: 10))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func behaviorHint(_ behavior: BlockBehavior) -> String {
        switch behavior {
        case .none: return ""
        case .spawn: return "Players start on top of this block."
        case .checkpoint: return "Touching it sets where the player respawns. Players walk through it."
        case .hazard: return "Touching it sends the player back to their last checkpoint."
        case .collectible: return "Each player can collect it once. Players walk through it."
        case .goal: return "Touching it ends the round for everyone."
        case .trigger: return "Does nothing by itself — add a rule that listens for it."
        }
    }

    private func flagsSection(_ block: BlockData) -> some View {
        InspectorGroup("Physics") {
            VStack(alignment: .leading, spacing: 7) {
                toggle("Anchored", isOn: block.isAnchored, hint: "Stays put. Turn off to let it fall in Play mode.") { newValue in
                    session.edit { $0.mutateSelection(label: "Toggle anchored") { $0.isAnchored = newValue } }
                }
                toggle("Solid", isOn: block.hasCollision, hint: "Players can walk through it when off.") { newValue in
                    session.edit { $0.mutateSelection(label: "Toggle collision") { $0.hasCollision = newValue } }
                }
                toggle("Visible", isOn: block.isVisible, hint: nil) { newValue in
                    session.edit { $0.mutateSelection(label: "Toggle visibility") { $0.isVisible = newValue } }
                }
            }
        }
    }

    private func tagsSection(_ block: BlockData) -> some View {
        InspectorGroup("Tags") {
            VStack(alignment: .leading, spacing: 7) {
                TextField("coin, trap, door…", text: Binding(
                    get: { block.tags.joined(separator: ", ") },
                    set: { newValue in
                        let tags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        session.edit { $0.mutateSelection(label: "Edit tags") { $0.tags = tags } }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .autocorrectionDisabled()
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text("A rule can listen for any block with a tag, so one rule can cover a whole group.")
                    .font(.system(size: 10))
                    .foregroundStyle(Ablox.Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Multi-selection

    private var multiSelectionBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorGroup("Colour all") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 7)], spacing: 7) {
                    ForEach(ColorRGBA.palette, id: \.hexString) { color in
                        ColorSwatch(color: color, isSelected: false, size: 28) {
                            session.edit { $0.mutateSelection(label: "Recolour") { $0.color = color } }
                        }
                    }
                }
            }

            InspectorGroup("Nudge all") {
                VStack(spacing: 7) {
                    nudgeRow("Move", axes: ["X", "Y", "Z"]) { axis, amount in
                        let offset = Vec3(axis == 0 ? amount : 0, axis == 1 ? amount : 0, axis == 2 ? amount : 0)
                        session.edit { $0.translateSelection(by: offset) }
                    }
                }
            }

            InspectorGroup("Actions") {
                VStack(spacing: 7) {
                    Button { session.duplicateSelection() } label: {
                        Label("Duplicate", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))

                    Button(role: .destructive) { session.deleteSelection() } label: {
                        Label("Delete all", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.destructive, fullWidth: true))
                }
            }
        }
    }

    private func nudgeRow(_ title: String, axes: [String], action: @escaping (Int, Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
            ForEach(Array(axes.enumerated()), id: \.offset) { index, axis in
                HStack(spacing: 5) {
                    Text(axis)
                        .font(.caption2.weight(.bold).monospaced())
                        .frame(width: 14)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                    Button("−") { action(index, -session.document.gridSize) }
                        .buttonStyle(StepButtonStyle())
                    Button("+") { action(index, session.document.gridSize) }
                        .buttonStyle(StepButtonStyle())
                    Spacer()
                }
            }
        }
    }

    // MARK: World

    private var environmentSection: some View {
        let environment = session.document.world.environment

        return VStack(alignment: .leading, spacing: 18) {
            InspectorGroup("World name") {
                TextField("World", text: Binding(
                    get: { session.document.world.name },
                    set: { newName in
                        session.edit { document in document.renameWorld(newName) }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            InspectorGroup("Lighting") {
                VStack(alignment: .leading, spacing: 9) {
                    labelledSlider("Brightness", value: environment.ambientIntensity, range: 0.1...1.5) { newValue in
                        var updated = environment
                        updated.ambientIntensity = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    labelledSlider("Sun height", value: environment.sunPitchDegrees, range: -89...(-5), unit: "°") { newValue in
                        var updated = environment
                        updated.sunPitchDegrees = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    labelledSlider("Sun direction", value: environment.sunYawDegrees, range: -180...180, unit: "°") { newValue in
                        var updated = environment
                        updated.sunYawDegrees = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                }
            }

            InspectorGroup("Physics") {
                VStack(alignment: .leading, spacing: 9) {
                    labelledSlider("Gravity", value: environment.gravity, range: -30...(-1), unit: "m/s²") { newValue in
                        var updated = environment
                        updated.gravity = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    labelledSlider("Fall limit", value: environment.killPlaneHeight, range: -200...(-5), unit: "m") { newValue in
                        var updated = environment
                        updated.killPlaneHeight = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    Text("A player who falls below the fall limit respawns.")
                        .font(.system(size: 10))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorGroup("Ground") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Show backdrop", isOn: Binding(
                        get: { environment.showGroundPlane },
                        set: { newValue in
                            var updated = environment
                            updated.showGroundPlane = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ))
                    .font(.caption)
                    .tint(Ablox.Palette.accent)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 7)], spacing: 7) {
                        ForEach(ColorRGBA.palette, id: \.hexString) { color in
                            ColorSwatch(color: color, isSelected: environment.groundColor == color, size: 28) {
                                var updated = environment
                                updated.groundColor = color
                                session.edit { $0.setEnvironment(updated) }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    private func vectorField(
        _ title: String,
        value: Vec3,
        step: Float,
        minimum: Float? = nil,
        unit: String = "",
        onChange: @escaping (Vec3) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
            HStack(spacing: 5) {
                axisField("X", value.x, step: step, minimum: minimum, unit: unit) { onChange(Vec3($0, value.y, value.z)) }
                axisField("Y", value.y, step: step, minimum: minimum, unit: unit) { onChange(Vec3(value.x, $0, value.z)) }
                axisField("Z", value.z, step: step, minimum: minimum, unit: unit) { onChange(Vec3(value.x, value.y, $0)) }
            }
        }
    }

    private func axisField(
        _ axis: String,
        _ value: Float,
        step: Float,
        minimum: Float?,
        unit: String,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            Text(axis)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Ablox.Palette.inkFaint)
            HStack(spacing: 0) {
                Button("−") {
                    let next = value - step
                    onChange(minimum.map { Swift.max($0, next) } ?? next)
                }
                .buttonStyle(StepButtonStyle())

                Text(format(value) + unit)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Ablox.Palette.ink)

                Button("+") { onChange(value + step) }
                    .buttonStyle(StepButtonStyle())
            }
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func format(_ value: Float) -> String {
        // Whole numbers read better without a trailing ".0" in a narrow field.
        abs(value.rounded() - value) < 0.01
            ? String(Int(value.rounded()))
            : String(format: "%.2f", value)
    }

    private func labelledPicker<T: Hashable>(
        _ title: String,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) -> some View {
        HStack {
            Text(title).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.caption)
            .tint(Ablox.Palette.accent)
        }
    }

    private func labelledSlider(
        _ title: String,
        value: Float,
        range: ClosedRange<Float>,
        unit: String = "",
        onChange: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
                Spacer()
                Text(String(format: "%.1f%@", value, unit))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Ablox.Palette.accent)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .tint(Ablox.Palette.accent)
                .controlSize(.mini)
        }
    }

    private func toggle(_ title: String, isOn: Bool, hint: String?, onChange: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .font(.caption)
                .tint(Ablox.Palette.accent)
            if let hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(Ablox.Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shared pieces

struct InspectorGroup<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Ablox.Palette.inkFaint)
            content
        }
    }
}

struct StepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .frame(width: 22, height: 20)
            .background(configuration.isPressed ? Ablox.Palette.accent.opacity(0.3) : Color.white.opacity(0.07))
            .foregroundStyle(Ablox.Palette.ink)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
