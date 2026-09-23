import SwiftUI

/// The Script tab: what the world's script is doing, the way into editing it,
/// and ready-made games to start from.
///
/// Rules are the pickers-only half of making a game; this is the other half,
/// for what rules cannot say — a first-person shooter, teams, a timer on the
/// screen, buttons.
struct ScriptPanel: View {
    @ObservedObject var session: StudioSession

    @State private var showEditor = false
    @State private var pendingSample: ScriptSample?

    private var script: String? { session.document.world.script }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard

                    Button {
                        showEditor = true
                    } label: {
                        Label(script == nil ? L("Write a script") : L("Open the script editor"), systemImage: "curlybraces")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary))

                    Text(L("Start from an example"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .padding(.top, 6)

                    ForEach(ScriptSamples.all) { sample in
                        sampleRow(sample)
                    }
                }
                .padding(14)
            }
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showEditor) {
            ScriptEditorView(session: session)
        }
        .alert(L("Replace the current script?"), isPresented: Binding(
            get: { pendingSample != nil },
            set: { if !$0 { pendingSample = nil } }
        )) {
            Button(L("Replace"), role: .destructive) {
                if let sample = pendingSample { use(sample) }
            }
            Button(L("Cancel"), role: .cancel) { pendingSample = nil }
        } message: {
            Text(L("Your script will be swapped for the example. Undo brings it back."))
        }
    }

    private var header: some View {
        HStack {
            Label(L("Script"), systemImage: "curlybraces")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Ablox.Palette.ink)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let script {
                    let problems = GameRuntime.check(script)
                    let lines = script.split(separator: "\n", omittingEmptySubsequences: false).count
                    Label(L("{} lines", lines), systemImage: "doc.plaintext")
                        .font(.subheadline.weight(.semibold))
                    if problems.isEmpty {
                        Label(L("No problems found"), systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.success)
                    } else {
                        Label(L("{} problems", problems.count), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.warning)
                        Text(verbatim: problems[0].description)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Ablox.Palette.inkMuted)
                            .lineLimit(3)
                    }
                } else {
                    Text(L("No script yet"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("Scripts make the games rules can't: shooters, teams, timers and buttons on the screen."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sampleRow(_ sample: ScriptSample) -> some View {
        Button {
            if script == nil { use(sample) } else { pendingSample = sample }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sample.symbolName)
                    .font(.headline)
                    .foregroundStyle(Ablox.Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: sample.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ablox.Palette.ink)
                    Text(verbatim: sample.summary)
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func use(_ sample: ScriptSample) {
        pendingSample = nil
        session.edit { $0.setScript(sample.source) }
        showEditor = true
    }
}

/// The editor itself: a code view, Check and Test run, the examples, and the
/// reference, side by side.
struct ScriptEditorView: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var problems: [ScriptError] = []
    @State private var report: ScriptTestReport?
    @State private var showReference = true
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TextEditor(text: $draft)
                        .font(.system(size: 15, design: .monospaced))
                        // Code, not prose: no capitals at the start of a
                        // line, no "corrections" of `func` into `fun`.
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.black.opacity(0.35))
                        .focused($editorFocused)
                        .onChange(of: draft) { _, _ in scheduleCommit() }

                    Divider().background(Color.white.opacity(0.08))
                    results
                        .frame(height: 190)
                }

                if showReference {
                    Divider().background(Color.white.opacity(0.08))
                    ScriptReferenceView()
                        .frame(width: 320)
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle(L("Script"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Done")) {
                        commitNow()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        check()
                    } label: {
                        Label(L("Check"), systemImage: "checkmark.seal")
                    }
                    Button {
                        testRun()
                    } label: {
                        Label(L("Test run"), systemImage: "play.circle")
                    }
                    Menu {
                        ForEach(ScriptSamples.all) { sample in
                            Button {
                                draft = sample.source
                            } label: {
                                Label(sample.title, systemImage: sample.symbolName)
                            }
                        }
                    } label: {
                        Label(L("Examples"), systemImage: "doc.on.doc")
                    }
                    Button {
                        withAnimation { showReference.toggle() }
                    } label: {
                        Label(L("Reference"), systemImage: "book")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            draft = session.document.world.script ?? ""
            // One undo step for the whole visit, not one per keystroke.
            session.edit { $0.beginGesture() }
            check()
        }
        .task {
            // Focus once the sheet has finished presenting. Asked for any
            // earlier, some iPads drop the request and no keyboard appears.
            try? await Task.sleep(nanoseconds: 600_000_000)
            editorFocused = true
        }
        .onDisappear {
            commitNow()
            session.edit { $0.endGesture() }
        }
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if problems.isEmpty, report == nil {
                    Label(L("No problems found"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Ablox.Palette.success)
                        .font(.subheadline.weight(.semibold))
                }
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                    Label {
                        Text(verbatim: problem.description)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(problem.kind == .syntax ? Ablox.Palette.danger : Ablox.Palette.warning)
                }
                if let report {
                    Text(L("Test run: two players, nobody pressing anything"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .padding(.top, 4)
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                        Text(verbatim: "• " + note)
                            .font(.footnote)
                            .foregroundStyle(Ablox.Palette.ink)
                    }
                    ForEach(Array(report.output.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: "> " + line)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Ablox.Palette.accent)
                    }
                    if report.notes.isEmpty, report.output.isEmpty, report.isClean {
                        Text(L("It ran without errors, but did nothing anyone could see."))
                            .font(.footnote)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    // MARK: Actions

    private func check() {
        commitNow()
        report = nil
        problems = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : GameRuntime.check(draft)
    }

    private func testRun() {
        commitNow()
        var world = session.document.world
        world.script = draft
        let result = GameRuntime.testRun(world: world, seconds: 5)
        problems = result.problems
        report = result
    }

    /// Saves after a pause in typing, so co-editors see the script without
    /// being sent every keystroke.
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            commitNow()
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        let current = session.document.world.script ?? ""
        guard draft != current else { return }
        session.edit { $0.setScript(draft) }
    }
}

/// Everything a script can use, grouped, beside the editor.
struct ScriptReferenceView: View {
    var body: some View {
        List {
            ForEach(ScriptReference.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: entry.code)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Ablox.Palette.accent)
                                .textSelection(.enabled)
                            Text(verbatim: entry.explanation)
                                .font(.caption)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label(section.title, systemImage: section.symbolName)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}
