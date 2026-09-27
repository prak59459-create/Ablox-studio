import SwiftUI
import UniformTypeIdentifiers

/// Properties of whatever is selected.
struct InspectorPanel: View {
    @ObservedObject var session: StudioSession

    /// Choosing a picture from Files, and the block it is for (nil: just
    /// add it to the world).
    @State private var importingPicture = false
    @State private var pictureFor: UUID?
    @State private var pictureProblem: String?

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
        .fileImporter(isPresented: $importingPicture, allowedContentTypes: [.image]) { result in
            addPicture(result)
        }
        .alert(L("That picture can't be used"), isPresented: Binding(
            get: { pictureProblem != nil },
            set: { if !$0 { pictureProblem = nil } }
        )) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(pictureProblem ?? "")
        }
    }

    // MARK: Pictures

    private func addPicture(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard world.images.count < WorldImage.maximumCount else {
            pictureProblem = L("A world can have up to {} pictures. Remove one in the World panel first.", WorldImage.maximumCount)
            return
        }
        guard let data = try? Data(contentsOf: url), let small = PictureShrinker.shrink(data) else {
            pictureProblem = L("It isn't a picture Ablox can read. Try a PNG or JPEG.")
            return
        }
        let picture = WorldImage(name: url.deletingPathExtension().lastPathComponent, data: small)
        let target = pictureFor
        session.edit { document in
            document.setImages(document.world.images + [picture])
            if let target, document.world.block(id: target) != nil {
                document.mutateSelection(label: "Show picture") { $0.imageID = picture.id }
            }
        }
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
        InspectorGroup(L("Name")) {
            AbloxTextField(L("Part"), text: Binding(
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
        InspectorGroup(L("Transform")) {
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
        InspectorGroup(L("Appearance")) {
            VStack(alignment: .leading, spacing: 11) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 7)], spacing: 7) {
                    ForEach(ColorRGBA.palette, id: \.hexString) { color in
                        ColorSwatch(color: color, isSelected: block.color == color, size: 28) {
                            session.edit { $0.mutateSelection(label: "Recolour") { $0.color = color } }
                        }
                    }
                }

                labelledPicker(L("Shape"), selection: Binding(
                    get: { block.shape },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change shape") { $0.shape = newValue } }
                    }
                ), options: BlockShape.allCases) { $0.displayName }

                labelledPicker(L("Material"), selection: Binding(
                    get: { block.material },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change material") { $0.material = newValue } }
                    }
                ), options: MaterialKind.allCases) { $0.displayName }

                labelledPicker(L("Particles"), selection: Binding(
                    get: { block.particles },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change particles") { $0.particles = newValue } }
                    }
                ), options: [nil] + ParticleKind.allCases.map(Optional.some)) { $0?.displayName ?? L("None") }

                HStack {
                    labelledPicker(L("Picture"), selection: Binding(
                        get: { block.imageID },
                        set: { newValue in
                            session.edit { $0.mutateSelection(label: "Change picture") { $0.imageID = newValue } }
                        }
                    ), options: [nil] + world.images.map { Optional.some($0.id) }) { id in
                        id.flatMap { world.image(id: $0)?.name } ?? L("None")
                    }
                    Button {
                        pictureFor = block.id
                        importingPicture = true
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ablox.Palette.accent)
                    .accessibilityLabel(L("Add a picture"))
                }
            }
        }
    }

    private func behaviorSection(_ block: BlockData) -> some View {
        InspectorGroup(L("Behaviour")) {
            VStack(alignment: .leading, spacing: 9) {
                labelledPicker(L("Acts as"), selection: Binding(
                    get: { block.behavior },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change behaviour") { $0.behavior = newValue } }
                    }
                ), options: BlockBehavior.allCases) { $0.displayName }

                // Only collectibles and hazards do anything with a score, so
                // the field appears only when it means something.
                if block.behavior == .collectible || block.behavior == .hazard {
                    HStack {
                        Text(block.behavior == .collectible ? L("Points") : L("Penalty"))
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

                if block.behavior == .checkpoint {
                    HStack {
                        Text(L("Stage")).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
                        Spacer()
                        Stepper(value: Binding(
                            get: { block.gimmick.stage },
                            set: { newValue in
                                session.edit { $0.mutateSelection(label: "Change stage") { $0.gimmick.stage = newValue } }
                            }
                        ), in: 0...999) {
                            Text(block.gimmick.stage == 0 ? L("Any order") : "\(block.gimmick.stage)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Ablox.Palette.accent)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                if block.behavior == .elevator || block.behavior == .ladder {
                    // Worked out on each iPad: no cooldown to tune.
                    gimmickFields(block)
                } else if block.behavior.isGimmick {
                    gimmickFields(block)
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

    /// The tuning an author actually needs for the gimmick they picked, and
    /// nothing else — a bounce pad has no business showing a teleport target.
    @ViewBuilder
    private func gimmickFields(_ block: BlockData) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            switch block.behavior {
            case .bounce:
                gimmickSlider(L("Launch speed"), value: block.gimmick.bounceSpeed, range: 6...30, unit: " m/s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change launch speed") { $0.gimmick.bounceSpeed = newValue } }
                }

            case .disappear:
                gimmickSlider(L("Delay before it goes"), value: Float(block.gimmick.disappearDelay), range: 0...2, unit: " s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change delay") { $0.gimmick.disappearDelay = Double(newValue) } }
                }
                gimmickSlider(L("Time until it returns"), value: Float(block.gimmick.respawnDelay), range: 0.5...15, unit: " s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change respawn") { $0.gimmick.respawnDelay = Double(newValue) } }
                }

            case .teleport:
                HStack {
                    Text(L("Sends you to")).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
                    Spacer()
                    Picker(L("Target"), selection: Binding(
                        get: { block.gimmick.teleportTargetID ?? Self.noTeleportTarget },
                        set: { newValue in
                            let target = newValue == Self.noTeleportTarget ? nil : newValue
                            session.edit { $0.mutateSelection(label: "Change target") { $0.gimmick.teleportTargetID = target } }
                        }
                    )) {
                        Text(L("Nowhere")).tag(Self.noTeleportTarget)
                        // A pad pointing at itself would teleport the player
                        // onto the pad, forever.
                        ForEach(world.blocks.filter { $0.id != block.id }) { candidate in
                            Text(candidate.name).tag(candidate.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.caption)
                    .tint(Ablox.Palette.accent)
                }

            case .door:
                gimmickSlider(L("Stays open for"), value: Float(block.gimmick.doorSeconds), range: 0.5...15, unit: " s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change door time") { $0.gimmick.doorSeconds = Double(newValue) } }
                }

            case .elevator:
                vectorField(L("Moves by"), value: block.gimmick.moveOffset, step: 1, unit: "m") { newValue in
                    session.edit { $0.mutateSelection(label: "Change movement") { $0.gimmick.moveOffset = newValue } }
                }
                gimmickSlider(L("Time to get there"), value: Float(block.gimmick.moveSeconds), range: 0.5...20, unit: " s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change speed") { $0.gimmick.moveSeconds = Double(newValue) } }
                }
                gimmickSlider(L("Wait at each end"), value: Float(block.gimmick.movePause), range: 0...10, unit: " s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change wait") { $0.gimmick.movePause = Double(newValue) } }
                }

            case .vehicle:
                labelledPicker(L("Vehicle"), selection: Binding(
                    get: { AvatarProfile.Ride(rawValue: block.gimmick.vehicle) ?? .car },
                    set: { newValue in
                        session.edit { $0.mutateSelection(label: "Change vehicle") { $0.gimmick.vehicle = newValue.rawValue } }
                    }
                ), options: AvatarProfile.Ride.allCases.filter { $0 != .none }) { $0.rawValue.capitalized }
                gimmickSlider(L("Speed"), value: block.gimmick.vehicleSpeed, range: 1...4, unit: "×") { newValue in
                    session.edit { $0.mutateSelection(label: "Change speed") { $0.gimmick.vehicleSpeed = newValue } }
                }

            default:
                EmptyView()
            }

            if block.behavior != .elevator && block.behavior != .ladder {
                gimmickSlider(L("Wait between uses"), value: Float(block.gimmick.cooldown), range: 0...5, unit: " s") { newValue in
                    session.edit { $0.mutateSelection(label: "Change cooldown") { $0.gimmick.cooldown = Double(newValue) } }
                }
            }
        }
    }

    /// Sentinel for "no target", since a Picker tag cannot be nil.
    private static let noTeleportTarget = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func gimmickSlider(
        _ title: String,
        value: Float,
        range: ClosedRange<Float>,
        unit: String,
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

    private var world: WorldDocument { session.document.world }

    /// The one-line explanation under the behaviour picker.
    ///
    /// The sentences live on `BlockBehavior` itself, because Studio's
    /// map-making guide lists the same ten behaviours — and explaining one
    /// two different ways in the same app is worse than explaining it badly.
    private func behaviorHint(_ behavior: BlockBehavior) -> String {
        behavior == .none ? "" : behavior.guidance
    }

    private func flagsSection(_ block: BlockData) -> some View {
        InspectorGroup(L("Physics")) {
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
        InspectorGroup(L("Tags")) {
            VStack(alignment: .leading, spacing: 7) {
                AbloxTextField(L("coin, trap, door…"), text: Binding(
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

                Text(L("A rule can listen for any block with a tag, so one rule can cover a whole group."))
                    .font(.system(size: 10))
                    .foregroundStyle(Ablox.Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Multi-selection

    private var multiSelectionBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorGroup(L("Colour all")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 7)], spacing: 7) {
                    ForEach(ColorRGBA.palette, id: \.hexString) { color in
                        ColorSwatch(color: color, isSelected: false, size: 28) {
                            session.edit { $0.mutateSelection(label: "Recolour") { $0.color = color } }
                        }
                    }
                }
            }

            InspectorGroup(L("Nudge all")) {
                VStack(spacing: 7) {
                    nudgeRow("Move", axes: ["X", "Y", "Z"]) { axis, amount in
                        let offset = Vec3(axis == 0 ? amount : 0, axis == 1 ? amount : 0, axis == 2 ? amount : 0)
                        session.edit { $0.translateSelection(by: offset) }
                    }
                }
            }

            InspectorGroup(L("Actions")) {
                VStack(spacing: 7) {
                    Button { session.duplicateSelection() } label: {
                        Label(L("Duplicate"), systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))

                    Button(role: .destructive) { session.deleteSelection() } label: {
                        Label(L("Delete all"), systemImage: "trash").frame(maxWidth: .infinity)
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
            InspectorGroup(L("World name")) {
                AbloxTextField(L("World"), text: Binding(
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

            InspectorGroup(L("Lighting")) {
                VStack(alignment: .leading, spacing: 9) {
                    labelledSlider(L("Brightness"), value: environment.ambientIntensity, range: 0.1...1.5) { newValue in
                        var updated = environment
                        updated.ambientIntensity = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    labelledSlider(L("Sun height"), value: environment.sunPitchDegrees, range: -89...(-5), unit: "°") { newValue in
                        var updated = environment
                        updated.sunPitchDegrees = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    labelledSlider(L("Sun direction"), value: environment.sunYawDegrees, range: -180...180, unit: "°") { newValue in
                        var updated = environment
                        updated.sunYawDegrees = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                }
            }

            InspectorGroup(L("Sky and weather")) {
                VStack(alignment: .leading, spacing: 9) {
                    labelledPicker(L("Weather"), selection: Binding(
                        get: { environment.weather },
                        set: { newValue in
                            var updated = environment
                            updated.weather = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ), options: Weather.allCases) { $0.displayName }
                    labelledPicker(L("Sky"), selection: Binding(
                        get: { environment.skyStyle },
                        set: { newValue in
                            var updated = environment
                            updated.skyStyle = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ), options: SkyStyle.allCases) { $0.displayName }
                    labelledPicker(L("Screen look"), selection: Binding(
                        get: { environment.screenEffect },
                        set: { newValue in
                            var updated = environment
                            updated.screenEffect = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ), options: ScreenEffect.allCases) { $0.displayName }
                    labelledPicker(L("Music"), selection: Binding(
                        get: { environment.music },
                        set: { newValue in
                            var updated = environment
                            updated.music = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ), options: [nil] + MusicTrack.allCases.map(Optional.some)) { $0?.displayName ?? L("None") }
                    Toggle(L("Shadows"), isOn: Binding(
                        get: { environment.shadows },
                        set: { newValue in
                            var updated = environment
                            updated.shadows = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ))
                    .font(.caption)
                    .tint(Ablox.Palette.accent)
                    Toggle(L("Time of day"), isOn: Binding(
                        get: { environment.timeOfDay != nil },
                        set: { newValue in
                            var updated = environment
                            updated.timeOfDay = newValue ? 12 : nil
                            if !newValue { updated.dayLengthMinutes = 0 }
                            session.edit { $0.setEnvironment(updated) }
                        }
                    ))
                    .font(.caption)
                    .tint(Ablox.Palette.accent)
                    if let hour = environment.timeOfDay {
                        labelledSlider(L("Starts at"), value: hour, range: 0...24, unit: ":00") { newValue in
                            var updated = environment
                            updated.timeOfDay = newValue
                            session.edit { $0.setEnvironment(updated) }
                        }
                        labelledSlider(L("A day lasts"), value: environment.dayLengthMinutes, range: 0...60, unit: " min") { newValue in
                            var updated = environment
                            updated.dayLengthMinutes = newValue.rounded()
                            session.edit { $0.setEnvironment(updated) }
                        }
                        Text(L("0 minutes keeps the sun still. Otherwise the day goes round while people play."))
                            .font(.system(size: 10))
                            .foregroundStyle(Ablox.Palette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            InspectorGroup(L("Pictures")) {
                VStack(alignment: .leading, spacing: 7) {
                    if world.images.isEmpty {
                        Text(L("Pictures from Files can be shown on blocks. Pick a part, then Picture."))
                            .font(.system(size: 10))
                            .foregroundStyle(Ablox.Palette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(world.images) { picture in
                        HStack(spacing: 8) {
                            if let image = UIImage(data: picture.data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 30, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            Text(picture.name).font(.caption).lineLimit(1)
                            Spacer()
                            Button {
                                session.edit { document in
                                    document.setImages(document.world.images.filter { $0.id != picture.id })
                                }
                            } label: {
                                Image(systemName: "trash").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Ablox.Palette.danger)
                            .accessibilityLabel(L("Remove {}", picture.name))
                        }
                    }
                    if world.images.count < WorldImage.maximumCount {
                        Button {
                            pictureFor = nil
                            importingPicture = true
                        } label: {
                            Label(L("Add a picture"), systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))
                    }
                }
            }

            InspectorGroup(L("Physics")) {
                VStack(alignment: .leading, spacing: 9) {
                    labelledSlider(L("Gravity"), value: environment.gravity, range: -30...(-1), unit: "m/s²") { newValue in
                        var updated = environment
                        updated.gravity = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    labelledSlider(L("Fall limit"), value: environment.killPlaneHeight, range: -200...(-5), unit: "m") { newValue in
                        var updated = environment
                        updated.killPlaneHeight = newValue
                        session.edit { $0.setEnvironment(updated) }
                    }
                    Text(L("A player who falls below the fall limit respawns."))
                        .font(.system(size: 10))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorGroup(L("Ground")) {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle(L("Show backdrop"), isOn: Binding(
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

/// Makes a picture small enough to live in a world file: at most 512 points
/// across, as a JPEG, stepping the quality down until it fits.
enum PictureShrinker {
    static func shrink(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 512 / longest)
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in stride(from: 0.85, through: 0.3, by: -0.1) {
            if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= WorldImage.maximumBytes {
                return jpeg
            }
        }
        return nil
    }
}
