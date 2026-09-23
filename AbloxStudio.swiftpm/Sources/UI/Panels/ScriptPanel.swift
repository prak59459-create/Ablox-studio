import SwiftUI
import UniformTypeIdentifiers

/// The Script tab: the world's `.absc` files, and the way into editing them.
///
/// Rules are the pickers-only half of making a game; scripts are the other
/// half, for everything rules cannot say — a first-person shooter, a menu, an
/// NPC that chases you, a map that builds itself.
struct ScriptPanel: View {
    @ObservedObject var session: StudioSession

    @State private var editing: ScriptFileSelection?
    @State private var renaming: ScriptFile?
    @State private var newName = ""
    @State private var showImporter = false
    @State private var exportItem: ScriptExport?
    @State private var importMessage: String?

    init(session: StudioSession) {
        self.session = session
    }

    private var files: [ScriptFile] { session.document.world.scripts }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusCard

                    ForEach(files) { file in
                        fileRow(file)
                    }

                    HStack(spacing: 8) {
                        Button {
                            if let id = addFile(named: files.isEmpty ? "main" : "script", source: "") {
                                editing = ScriptFileSelection(id: id)
                            }
                        } label: {
                            Label(L("New file"), systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.primary))

                        Button {
                            showImporter = true
                        } label: {
                            Label(L("Import"), systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.secondary))
                    }

                    if let importMessage {
                        Text(verbatim: importMessage)
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.warning)
                    }

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
        .sheet(item: $editing) { selection in
            ScriptEditorView(session: session, fileID: selection.id)
        }
        .sheet(item: $exportItem) { item in
            ScriptExportSheet(item: item)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .plainText], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .alert(L("Rename file"), isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField(L("File name"), text: $newName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L("Rename")) {
                if let file = renaming { session.edit { $0.renameScript(file.id, to: newName) } }
                renaming = nil
            }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
    }

    private var header: some View {
        HStack {
            Label(L("Script"), systemImage: "curlybraces")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Ablox.Palette.ink)
            Spacer()
            Text(verbatim: "." + ScriptFile.fileExtension)
                .font(.caption.monospaced())
                .foregroundStyle(Ablox.Palette.inkFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if files.isEmpty {
                    Text(L("No script yet"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("Scripts make the games rules can't: shooters, menus, NPCs, maps that change, anything."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let problems = GameRuntime.check(files)
                    Label(L("{} files", files.count), systemImage: "doc.on.doc")
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileRow(_ file: ScriptFile) -> some View {
        HStack(spacing: 10) {
            Button {
                editing = ScriptFileSelection(id: file.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.plaintext")
                        .foregroundStyle(file.isEnabled ? Ablox.Palette.accent : Ablox.Palette.inkFaint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.name)
                            .font(.subheadline.weight(.semibold).monospaced())
                            .foregroundStyle(file.isEnabled ? Ablox.Palette.ink : Ablox.Palette.inkFaint)
                            .lineLimit(1)
                        Text(L("{} lines", file.source.split(separator: "\n", omittingEmptySubsequences: false).count))
                            .font(.caption2)
                            .foregroundStyle(Ablox.Palette.inkFaint)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    newName = String(file.name.dropLast(ScriptFile.fileExtension.count + 1))
                    renaming = file
                } label: {
                    Label(L("Rename"), systemImage: "pencil")
                }
                Button {
                    session.edit { $0.setScriptEnabled(file.id, !file.isEnabled) }
                } label: {
                    Label(file.isEnabled ? L("Switch off") : L("Switch on"),
                          systemImage: file.isEnabled ? "pause.circle" : "play.circle")
                }
                Button {
                    exportItem = ScriptExport(file: file)
                } label: {
                    Label(L("Export .absc"), systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    session.edit { $0.removeScript(file.id) }
                } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sampleRow(_ sample: ScriptSample) -> some View {
        Button {
            if let id = addFile(named: sample.fileName, source: sample.source) {
                editing = ScriptFileSelection(id: id)
            }
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

    private func addFile(named name: String, source: String) -> UUID? {
        var id: UUID?
        session.edit { id = $0.addScript(named: name, source: source) }
        if id == nil { importMessage = L("A world can have up to {} script files.", ScriptFile.Limits.maximumFiles) }
        return id
    }

    /// `.absc` files from the Files app — written on a computer, sent by a
    /// friend, or exported from another world.
    private func importFiles(_ result: Result<[URL], Error>) {
        importMessage = nil
        guard case let .success(urls) = result else {
            importMessage = L("Those files could not be opened.")
            return
        }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= ScriptLexer.maximumSourceLength * 4,
                  let text = String(data: data, encoding: .utf8) else {
                importMessage = L("“{}” is not a text file.", url.lastPathComponent)
                continue
            }
            _ = addFile(named: url.lastPathComponent, source: text)
        }
    }
}

/// Which file the editor sheet is showing.
struct ScriptFileSelection: Identifiable {
    let id: UUID
}

/// A file being exported: written to a temporary `.absc` so the share sheet
/// hands over a real file with the right name.
struct ScriptExport: Identifiable {
    let id = UUID()
    let file: ScriptFile
    let url: URL?

    init(file: ScriptFile) {
        self.file = file
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        self.url = (try? file.source.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }
}

private struct ScriptExportSheet: View {
    let item: ScriptExport
    @Environment(\.dismiss) private var dismiss

    init(item: ScriptExport) {
        self.item = item
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 44))
                .foregroundStyle(Ablox.Palette.accent)
            Text(verbatim: item.file.name)
                .font(.title3.weight(.bold).monospaced())
            if let url = item.url {
                ShareLink(item: url) {
                    Label(L("Share or save to Files"), systemImage: "square.and.arrow.up")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(NeonButtonStyle(.primary))
            } else {
                Text(L("That file could not be written."))
                    .foregroundStyle(Ablox.Palette.warning)
            }
            Button(L("Done")) { dismiss() }
                .buttonStyle(NeonButtonStyle(.secondary))
        }
        .padding(30)
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

/// The editor: one `.absc` file as code, with Check and Test run for the
/// whole world, the examples, and the reference beside it.
struct ScriptEditorView: View {
    @ObservedObject var session: StudioSession
    let fileID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var problems: [ScriptError] = []
    @State private var report: ScriptTestReport?
    @State private var showReference = true
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    init(session: StudioSession, fileID: UUID) {
        self.session = session
        self.fileID = fileID
    }

    private var file: ScriptFile? { session.document.world.scripts.first { $0.id == fileID } }

    /// Every file as it will run, with this one as typed so far.
    private var filesWithDraft: [ScriptFile] {
        session.document.world.scripts.map { $0.id == fileID ? ScriptFile(id: $0.id, name: $0.name, source: draft, isEnabled: $0.isEnabled) : $0 }
    }

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
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle(file?.name ?? L("Script"))
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
            draft = file?.source ?? ""
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
        problems = GameRuntime.check(filesWithDraft)
    }

    private func testRun() {
        commitNow()
        var world = session.document.world
        world.scripts = filesWithDraft
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
        guard let file, draft != file.source else { return }
        session.edit { $0.updateScript(fileID, source: draft) }
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
