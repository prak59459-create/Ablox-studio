import SwiftUI
import UIKit

/// Asking an assistant for a level, without the app talking to one.
///
/// Studio writes the prompt and reads the answer back; the person carries the
/// text across themselves. That is not a limitation worked around — it is the
/// design. Ablox has no server, no account and no key, and its own Settings
/// screen tells people nothing leaves their network. Wiring in a cloud model
/// would contradict all of that, and it would put a bill and an API key
/// between a child and a level.
///
/// What makes this work rather than being a novelty is on the other side:
/// `MapPrompt` generates the prompt from the real part list and the real jump
/// physics, and `MapPlan` checks every value that comes back. An assistant
/// cannot name a block that does not exist, and cannot produce a world that
/// fails to open.
struct MapAISheet: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var settings: StudioSettings
    @Environment(\.dismiss) private var dismiss

    /// Called with the world that was imported, so the caller can open it.
    var onImported: (WorldDocument) -> Void

    @State private var request = MapPrompt.Request()
    @State private var answer = ""
    @State private var problems: [MapPlanProblem] = []
    @State private var note: String?
    @State private var copied = false

    private var prompt: String {
        MapPrompt.text(for: request, movement: .default)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    whatToMake
                    step(1, L("Copy the prompt"), content: promptStep)
                    step(2, L("Paste the answer"), content: answerStep)

                    if !problems.isEmpty { problemList }
                    if let note {
                        Label(note, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.success)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle(L("Make a map with AI"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ablox.Palette.accent)
    }

    // MARK: Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Studio writes the prompt. Paste it into whichever assistant you use, then paste the answer back."))
                .font(.callout)
                .foregroundStyle(Ablox.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Label(L("Nothing is sent from this iPad. You carry the text across yourself."), systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var whatToMake: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 13) {
                SectionHeader(L("What to make"), systemImage: "wand.and.stars")

                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Theme")).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
                    TextField(L("a floating ruin, a lava cave, a candy town…"), text: $request.theme)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Picker(L("Size"), selection: $request.size) {
                    ForEach(MapPrompt.Size.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L("Difficulty"), selection: $request.difficulty) {
                    ForEach(MapPrompt.Difficulty.allCases) { difficulty in
                        Text(difficulty.displayName).tag(difficulty)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(L("Coins"), isOn: $request.includeCoins).tint(Ablox.Palette.accent)
                Toggle(L("Hazards"), isOn: $request.includeHazards).tint(Ablox.Palette.accent)
                Toggle(L("Gimmicks"), isOn: $request.includeGimmicks).tint(Ablox.Palette.accent)
            }
        }
    }

    private var promptStep: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Shown, not hidden behind the button: someone should be able to
            // read what they are about to send before they send it.
            ScrollView {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
            }
            .frame(height: 150)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                UIPasteboard.general.string = prompt
                copied = true
            } label: {
                Label(copied ? L("Copied") : L("Copy the prompt"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
            // Reset when anything about the request changes, so the tick never
            // claims that a prompt nobody copied is on the clipboard.
            .onChange(of: request) { _, _ in copied = false }
        }
    }

    private var answerStep: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextEditor(text: $answer)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 130)
                .padding(7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if answer.isEmpty {
                        Text(L("Paste the JSON the assistant replied with"))
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.inkFaint)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }

            Button { build() } label: {
                Label(L("Import"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
            .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var problemList: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(L("What to fix"), systemImage: "exclamationmark.triangle.fill")

                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                    Text("• \(problem.description)")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The problems are already phrased as instructions, so this is
                // a straight paste back into the same conversation.
                Button {
                    UIPasteboard.general.string = MapPrompt.correction(for: problems)
                } label: {
                    Label(L("Copy what to fix"), systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Ablox.Palette.accent.opacity(0.25)))
                    .foregroundStyle(Ablox.Palette.accent)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Ablox.Palette.ink)
            }
            content()
        }
    }

    // MARK: Importing

    private func build() {
        note = nil

        switch MapPlan.decode(from: answer) {
        case let .failure(problem):
            problems = [problem]

        case let .success(plan):
            let result = plan.build(named: store.uniqueName(basedOn: L("AI World")))
            problems = result.problems

            guard var world = result.world else { return }
            world.authorName = settings.profile.displayName
            world.name = store.uniqueName(basedOn: world.name)

            guard store.save(world) else {
                problems = [MapPlanProblem(message: store.lastError ?? L("Could not save that world."))]
                return
            }

            // Problems can be non-empty and the world still good — a missing
            // spawn was filled in, say. Those are worth showing, but not worth
            // refusing over, so the note and the list appear together.
            note = L("Imported {} parts.", world.blocks.count)
            store.reload()
            onImported(world)
            if problems.isEmpty { dismiss() }
        }
    }
}
