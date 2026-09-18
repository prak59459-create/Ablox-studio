import SwiftUI

/// Visual rule editor.
///
/// Every trigger and action is a picker, never typed text. A closed vocabulary
/// cannot contain a syntax error, which matters a great deal when the person
/// building the world is eleven and the keyboard is on screen.
struct RulesPanel: View {
    @ObservedObject var session: StudioSession

    @State private var expandedRule: UUID?

    private var world: WorldDocument { session.document.world }
    private var rules: [EventRule] { world.rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if rules.isEmpty {
                EmptyStateView(
                    title: "No rules yet",
                    message: "Rules make things happen: touch a block to open a door, reach a score to win. Blocks marked Spawn, Coin, Hazard, Checkpoint and Goal already work without any.",
                    systemImage: "bolt.badge.clock"
                )
                .padding(.horizontal, 14)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rules) { rule in
                            ruleCard(rule)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Label("Rules", systemImage: "bolt.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Ablox.Palette.ink)
            Spacer()
            Button {
                addRule()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Ablox.Palette.accent)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add rule")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Rule card

    private func ruleCard(_ rule: EventRule) -> some View {
        let isExpanded = expandedRule == rule.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        expandedRule = isExpanded ? nil : rule.id
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .frame(width: 18, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: rule.trigger.symbolName)
                    .font(.caption)
                    .foregroundStyle(rule.isEnabled ? Ablox.Palette.accent : Ablox.Palette.inkFaint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rule.isEnabled ? Ablox.Palette.ink : Ablox.Palette.inkFaint)
                        .lineLimit(1)
                    Text(rule.summary)
                        .font(.system(size: 9))
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in update(rule) { $0.isEnabled = newValue } }
                ))
                .labelsHidden()
                .tint(Ablox.Palette.accent)
                .controlSize(.mini)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Rule name", text: Binding(
                        get: { rule.name },
                        set: { newValue in update(rule) { $0.name = newValue } }
                    ))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(7)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    triggerEditor(rule)
                    actionsEditor(rule)
                    limitsEditor(rule)

                    Button(role: .destructive) {
                        session.edit { $0.setRules(rules.filter { $0.id != rule.id }) }
                    } label: {
                        Label("Delete rule", systemImage: "trash")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.destructive, fullWidth: true))
                }
                .transition(.opacity)
            }
        }
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isExpanded ? Ablox.Palette.accent.opacity(0.4) : Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: Trigger

    private func triggerEditor(_ rule: EventRule) -> some View {
        InspectorGroup("When") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Trigger", selection: Binding(
                    get: { TriggerKind(rule.trigger) },
                    set: { kind in
                        update(rule) { $0.trigger = kind.makeTrigger(existing: $0.trigger, world: world) }
                    }
                )) {
                    ForEach(TriggerKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.caption)
                .tint(Ablox.Palette.accent)

                triggerParameters(rule)
            }
        }
    }

    @ViewBuilder
    private func triggerParameters(_ rule: EventRule) -> some View {
        switch rule.trigger {
        case let .blockTouched(blockID), let .blockTapped(blockID):
            blockPicker(selected: blockID) { newID in
                update(rule) {
                    if case .blockTouched = $0.trigger {
                        $0.trigger = .blockTouched(blockID: newID)
                    } else {
                        $0.trigger = .blockTapped(blockID: newID)
                    }
                }
            }

        case let .proximity(blockID, radius):
            blockPicker(selected: blockID) { newID in
                update(rule) { $0.trigger = .proximity(blockID: newID, radius: radius) }
            }
            stepperRow("Within", value: Double(radius), range: 1...30, step: 0.5, unit: " m") { newValue in
                update(rule) { $0.trigger = .proximity(blockID: blockID, radius: Float(newValue)) }
            }

        case let .tagTouched(tag):
            TextField("tag", text: Binding(
                get: { tag },
                set: { newValue in update(rule) { $0.trigger = .tagTouched(tag: newValue) } }
            ))
            .textFieldStyle(.plain)
            .font(.caption)
            .autocorrectionDisabled()
            .padding(7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        case let .timer(interval):
            stepperRow("Every", value: interval, range: 0.5...60, step: 0.5, unit: " s") { newValue in
                update(rule) { $0.trigger = .timer(interval: newValue) }
            }

        case let .scoreReached(score):
            stepperRow("Score", value: Double(score), range: 1...1000, step: 5, unit: "") { newValue in
                update(rule) { $0.trigger = .scoreReached(score: Int(newValue)) }
            }

        case .worldStart:
            EmptyView()
        }
    }

    // MARK: Actions

    private func actionsEditor(_ rule: EventRule) -> some View {
        InspectorGroup("Then") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { index, action in
                    HStack(spacing: 7) {
                        Image(systemName: action.symbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(Ablox.Palette.warning)
                            .frame(width: 14)
                        Text(action.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Ablox.Palette.ink)
                        Spacer(minLength: 4)
                        Button {
                            update(rule) { $0.actions.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Ablox.Palette.danger.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Menu {
                    ForEach(ActionKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) {
                            update(rule) { $0.actions.append(kind.makeAction(world: world, selection: session.document.primarySelection)) }
                        }
                    }
                } label: {
                    Label("Add action", systemImage: "plus")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Ablox.Palette.accent)
                }
            }
        }
    }

    private func limitsEditor(_ rule: EventRule) -> some View {
        InspectorGroup("Limits") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Only once", isOn: Binding(
                    get: { rule.maxFireCount == 1 },
                    set: { newValue in update(rule) { $0.maxFireCount = newValue ? 1 : nil } }
                ))
                .font(.caption)
                .tint(Ablox.Palette.accent)

                stepperRow("Wait between", value: rule.cooldown, range: 0...10, step: 0.25, unit: " s") { newValue in
                    update(rule) { $0.cooldown = newValue }
                }
            }
        }
    }

    // MARK: Helpers

    private func blockPicker(selected: UUID, onChange: @escaping (UUID) -> Void) -> some View {
        Picker("Block", selection: Binding(get: { selected }, set: onChange)) {
            // A rule can point at a block that has since been deleted; show
            // that rather than silently snapping to something else.
            if world.block(id: selected) == nil {
                Text("(deleted)").tag(selected)
            }
            ForEach(world.blocks) { block in
                Text(block.name).tag(block.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(.caption)
        .tint(Ablox.Palette.accent)
    }

    private func stepperRow(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        unit: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(title).font(.caption2).foregroundStyle(Ablox.Palette.inkMuted)
            Spacer()
            Text(String(format: value == value.rounded() ? "%.0f%@" : "%.2f%@", value, unit))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Ablox.Palette.accent)
            Stepper("", value: Binding(get: { value }, set: onChange), in: range, step: step)
                .labelsHidden()
                .controlSize(.mini)
        }
    }

    private func update(_ rule: EventRule, _ body: (inout EventRule) -> Void) {
        var updated = rules
        guard let index = updated.firstIndex(where: { $0.id == rule.id }) else { return }
        body(&updated[index])
        session.edit { $0.setRules(updated) }
    }

    private func addRule() {
        var rule = EventRule(name: "Rule \(rules.count + 1)")
        // Seed it against whatever is selected, so the common case — "make
        // this block do something" — needs no further picking.
        if let selected = session.document.primarySelection {
            rule.trigger = .blockTouched(blockID: selected.id)
            rule.actions = [.tint(blockID: selected.id, color: ColorRGBA.palette[4], duration: 0.4)]
        } else {
            rule.actions = [.announce(message: "Hello!", duration: 2)]
        }
        session.edit { $0.setRules(rules + [rule]) }
        expandedRule = rule.id
    }
}

// MARK: - Picker vocabularies

/// Flattens `EventTrigger`'s associated values into something a `Picker` can
/// select over, and knows how to build a sensible default of each case.
private enum TriggerKind: String, CaseIterable, Hashable {
    case blockTouched, tagTouched, blockTapped, proximity, worldStart, timer, scoreReached

    init(_ trigger: EventTrigger) {
        switch trigger {
        case .blockTouched: self = .blockTouched
        case .tagTouched: self = .tagTouched
        case .blockTapped: self = .blockTapped
        case .proximity: self = .proximity
        case .worldStart: self = .worldStart
        case .timer: self = .timer
        case .scoreReached: self = .scoreReached
        }
    }

    var displayName: String {
        switch self {
        case .blockTouched: return "A player touches a block"
        case .tagTouched: return "A player touches any tagged block"
        case .blockTapped: return "A player taps a block"
        case .proximity: return "A player comes close"
        case .worldStart: return "The round starts"
        case .timer: return "On a timer"
        case .scoreReached: return "A score is reached"
        }
    }

    /// Builds a trigger of this kind, reusing the existing block reference
    /// where possible so changing the kind does not lose the target.
    func makeTrigger(existing: EventTrigger, world: WorldDocument) -> EventTrigger {
        let blockID = existing.referencedBlockIDs.first ?? world.blocks.first?.id ?? UUID()
        switch self {
        case .blockTouched: return .blockTouched(blockID: blockID)
        case .tagTouched: return .tagTouched(tag: "coin")
        case .blockTapped: return .blockTapped(blockID: blockID)
        case .proximity: return .proximity(blockID: blockID, radius: 4)
        case .worldStart: return .worldStart
        case .timer: return .timer(interval: 2)
        case .scoreReached: return .scoreReached(score: 50)
        }
    }
}

private enum ActionKind: String, CaseIterable, Hashable {
    case tint, move, setVisible, setCollision, teleportPlayer, awardPoints, announce, playSound, endRound

    var displayName: String {
        switch self {
        case .tint: return "Change a block's colour"
        case .move: return "Move a block"
        case .setVisible: return "Hide a block"
        case .setCollision: return "Make a block walk-through"
        case .teleportPlayer: return "Teleport the player"
        case .awardPoints: return "Award points"
        case .announce: return "Show a message"
        case .playSound: return "Play a sound"
        case .endRound: return "End the round"
        }
    }

    func makeAction(world: WorldDocument, selection: BlockData?) -> EventAction {
        let blockID = selection?.id ?? world.blocks.first?.id ?? UUID()
        switch self {
        case .tint: return .tint(blockID: blockID, color: ColorRGBA.palette[4], duration: 0.4)
        case .move: return .move(blockID: blockID, offset: Vec3(0, 3, 0), duration: 1)
        case .setVisible: return .setVisible(blockID: blockID, visible: false)
        case .setCollision: return .setCollision(blockID: blockID, enabled: false)
        case .teleportPlayer: return .teleportPlayer(to: Vec3(0, 3, 0))
        case .awardPoints: return .awardPoints(10)
        case .announce: return .announce(message: "Nice!", duration: 2)
        case .playSound: return .playSound(name: "collect")
        case .endRound: return .endRound(message: "You win!")
        }
    }
}
