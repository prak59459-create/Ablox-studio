import SwiftUI
import UniformTypeIdentifiers
import AbloxCore

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
    @State private var editingSource = false
    @State private var pulling = false
    @State private var pullNote: PullNote?
    @State private var blockEditing: ScriptFileSelection?
    @State private var showLibrary = false
    @State private var showPush = false

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

                    HStack(spacing: 8) {
                        Button {
                            if let id = addFile(named: "blocks", source: BlockProgram().fileSource) {
                                blockEditing = ScriptFileSelection(id: id)
                            }
                        } label: {
                            Label(L("New with blocks"), systemImage: "square.stack.3d.up.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.secondary))

                        Button {
                            showLibrary = true
                        } label: {
                            Label(L("My library"), systemImage: "books.vertical")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.secondary))
                    }

                    if let importMessage {
                        Text(verbatim: importMessage)
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.warning)
                    }

                    githubCard

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
        .sheet(item: $blockEditing) { selection in
            BlockProgramEditor(session: session, fileID: selection.id) {
                turnIntoCode(selection.id)
            }
        }
        .sheet(isPresented: $showLibrary) {
            ScriptLibrarySheet(session: session)
        }
        .sheet(isPresented: $showPush) {
            GitHubPushSheet(session: session)
        }
        .sheet(item: $exportItem) { item in
            ScriptExportSheet(item: item)
        }
        .sheet(isPresented: $editingSource) {
            ScriptSourceSheet(current: session.document.world.scriptSource) { source in
                session.edit { $0.setScriptSource(source) }
                if source != nil { pull() } else { pullNote = nil }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .plainText], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        // A sheet rather than an alert: an alert's text field only types
        // with the iPad keyboard.
        .sheet(item: $renaming) { file in
            TextPromptSheet(title: L("Rename file"), placeholder: L("File name"), confirm: L("Rename"), text: $newName) {
                session.edit { $0.renameScript(file.id, to: newName) }
            }
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

    /// Whether a file was made with blocks (and opens as blocks).
    private func isBlocks(_ file: ScriptFile) -> Bool {
        file.source.hasPrefix(BlockProgram.marker)
    }

    /// Makes a block file ordinary code — the cards are dropped, the code
    /// they made stays — and opens it in the code editor.
    private func turnIntoCode(_ id: UUID) {
        if let file = files.first(where: { $0.id == id }), let program = BlockProgram(file: file) {
            session.edit { $0.updateScript(id, source: program.source) }
        }
        // After the block sheet has gone.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            editing = ScriptFileSelection(id: id)
        }
    }

    private func fileRow(_ file: ScriptFile) -> some View {
        HStack(spacing: 10) {
            Button {
                if isBlocks(file) {
                    blockEditing = ScriptFileSelection(id: file.id)
                } else {
                    editing = ScriptFileSelection(id: file.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isBlocks(file) ? "square.stack.3d.up.fill" : "doc.plaintext")
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
                Button {
                    ScriptLibraryStore.save(file)
                } label: {
                    Label(L("Save to my library"), systemImage: "books.vertical")
                }
                if isBlocks(file) {
                    Button {
                        turnIntoCode(file.id)
                    } label: {
                        Label(L("Turn into code"), systemImage: "curlybraces")
                    }
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

    // MARK: GitHub

    /// Where the files come from when they are written on a computer and
    /// pushed to a repository, and the button that brings them in.
    @ViewBuilder
    private var githubCard: some View {
        if let source = session.document.world.scriptSource {
            GlassCard(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(L("From GitHub"), systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            editingSource = true
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .accessibilityLabel(L("GitHub settings"))
                    }
                    Text(verbatim: source.displayName)
                        .font(.caption.monospaced())
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .lineLimit(2)
                    if source.updatesOnPlay {
                        Label(L("The latest files are fetched every time the game starts."), systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(Ablox.Palette.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        pull()
                    } label: {
                        HStack(spacing: 6) {
                            if pulling {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.to.line")
                            }
                            Text(L("Get the latest now"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary))
                    .disabled(pulling)

                    Button {
                        showPush = true
                    } label: {
                        Label(L("Push to GitHub"), systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))

                    if let pullNote {
                        Text(verbatim: pullNote.text)
                            .font(.caption)
                            .foregroundStyle(pullNote.isError ? Ablox.Palette.warning : Ablox.Palette.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Button {
                editingSource = true
            } label: {
                Label(L("Get .absc files from GitHub"), systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(.secondary))
        }
    }

    /// Brings every `.absc` in the source's folder into the world, as one
    /// undo step. Files only on the iPad are left alone.
    private func pull() {
        guard let source = session.document.world.scriptSource, !pulling else { return }
        pulling = true
        pullNote = nil
        Task { @MainActor in
            defer { pulling = false }
            do {
                let downloaded = try await ScriptFetcher.download(source, knownNames: files.map(\.name))
                guard !downloaded.isEmpty else {
                    pullNote = PullNote(text: L("No .absc files were found there."), isError: true)
                    return
                }
                var result = ScriptSyncResult()
                session.edit { result = $0.mergePulledScripts(downloaded) }
                pullNote = PullNote(text: result.summary, isError: false)
            } catch {
                pullNote = PullNote(text: ScriptFetcher.message(for: error), isError: true)
            }
        }
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

/// The line under the pull button: what changed, or why nothing could.
struct PullNote: Equatable {
    let text: String
    let isError: Bool
}

/// Which repository, branch and folder the world's `.absc` files come from.
struct ScriptSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let current: ScriptSource?
    /// Called with the new source, or nil to stop pulling from GitHub.
    let onSave: (ScriptSource?) -> Void

    @State private var repository: String
    @State private var branch: String
    @State private var folder: String
    @State private var updatesOnPlay: Bool

    init(current: ScriptSource?, onSave: @escaping (ScriptSource?) -> Void) {
        self.current = current
        self.onSave = onSave
        _repository = State(initialValue: current?.repository ?? "")
        _branch = State(initialValue: current?.branch ?? "main")
        _folder = State(initialValue: current?.folder ?? "")
        _updatesOnPlay = State(initialValue: current?.updatesOnPlay ?? false)
    }

    private var draft: ScriptSource {
        ScriptSource(repository: repository, branch: branch, folder: folder, updatesOnPlay: updatesOnPlay)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Write .absc files on a computer, push them to a public GitHub repository, and bring them into this world with one tap."))
                        .font(.callout)
                        .foregroundStyle(Ablox.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    field(L("Repository"), placeholder: "owner/repo", text: $repository)
                    HStack(spacing: 12) {
                        field(L("Branch"), placeholder: "main", text: $branch)
                        field(L("Folder (empty for the top)"), placeholder: "scripts", text: $folder)
                    }

                    if !repository.isEmpty, !draft.isValid {
                        Label(L("That repository, branch or folder is not valid."), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.warning)
                    } else if draft.isValid {
                        Text(verbatim: draft.displayName)
                            .font(.caption.monospaced())
                            .foregroundStyle(Ablox.Palette.inkFaint)
                    }

                    Toggle(isOn: $updatesOnPlay) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Get the latest every time the game starts"))
                                .font(.subheadline.weight(.medium))
                            Text(L("The host fetches the files again before each game, so a fix pushed to GitHub reaches everyone without publishing again. If GitHub cannot be reached, the saved files are used."))
                                .font(.caption)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Ablox.Palette.accent)

                    Label(L("Files with the same name are replaced. Files that are only on this iPad are kept."), systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(L("Only reads public repositories. Nothing is uploaded."), systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        onSave(draft)
                        dismiss()
                    } label: {
                        Label(L("Save and get files"), systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
                    .disabled(!draft.isValid)
                    .opacity(draft.isValid ? 1 : 0.5)

                    if current != nil {
                        Button(role: .destructive) {
                            onSave(nil)
                            dismiss()
                        } label: {
                            Label(L("Stop getting files from GitHub"), systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NeonButtonStyle(.destructive, fullWidth: true))
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle(L("Scripts from GitHub"))
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

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
            AbloxTextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.callout.monospaced())
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
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
///
/// The code is coloured in a theme of the player's choice, problem lines get
/// a red dotted underline (tap the problem to go there), suggestions sit
/// above the keyboard, and the More menu has snippets, tidying, the outline,
/// find and replace in every file, what changed, breakpoints and robots.
struct ScriptEditorView: View {
    @ObservedObject var session: StudioSession
    let fileID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    /// The file as it was when the editor opened, for "What changed".
    @State private var opened = ""
    @State private var problems: [ScriptError] = []
    @State private var report: ScriptTestReport?
    @State private var showReference = true
    @State private var commitTask: Task<Void, Never>?
    @StateObject private var handle = CodeEditorHandle()
    @AppStorage("ablox.studio.codeTheme") private var themeName = CodeTheme.night.rawValue
    @State private var tool: ScriptEditorTool?
    @State private var logFilter = LogFilter.all
    @State private var logSearch = ""
    @State private var note: String?

    init(session: StudioSession, fileID: UUID) {
        self.session = session
        self.fileID = fileID
    }

    private var file: ScriptFile? { session.document.world.scripts.first { $0.id == fileID } }

    /// Every file as it will run, with this one as typed so far.
    private var filesWithDraft: [ScriptFile] {
        session.document.world.scripts.map { $0.id == fileID ? ScriptFile(id: $0.id, name: $0.name, source: draft, isEnabled: $0.isEnabled) : $0 }
    }

    private var worldWithDraft: WorldDocument {
        var world = session.document.world
        world.scripts = filesWithDraft
        return world
    }

    private var theme: CodeTheme { CodeTheme(rawValue: themeName) ?? .night }

    private static let builtins = Set(GameRuntime.gameAPINames + ScriptInterpreter.standardLibraryNames)

    /// This file's problems (the others' are listed, but have no line here).
    private func isHere(_ problem: ScriptError) -> Bool {
        problem.file == nil || problem.file == file?.name
    }

    private var styling: CodeStyling {
        CodeStyling(theme: theme, builtins: Self.builtins,
                    problemLines: Set((problems + (report?.problems ?? [])).filter(isHere).map(\.line).filter { $0 > 0 }))
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Code, not prose: the editor turns off capitals at the
                    // start of a line and "corrections" of `func` into `fun`.
                    // It types with the Ablox keyboard when that is on.
                    AbloxTextEditor(L("Script"), text: $draft, autoFocus: true, handle: handle, styling: styling)
                        .padding(8)
                        .background(Color(theme.background))
                        .onChange(of: draft) { _, _ in scheduleCommit() }

                    CompletionBar(handle: handle, source: draft, blockNames: session.document.world.blocks.map(\.name))
                        .background(Color.black.opacity(0.3))

                    Divider().background(Color.white.opacity(0.08))
                    results
                        .frame(height: 200)
                }

                if showReference {
                    Divider().background(Color.white.opacity(0.08))
                    ScriptReferenceView { code in handle.replace(with: code) }
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
                        testRun(robots: false)
                    } label: {
                        Label(L("Test run"), systemImage: "play.circle")
                    }
                    moreMenu
                    Button {
                        withAnimation { showReference.toggle() }
                    } label: {
                        Label(L("Reference"), systemImage: "book")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $tool) { tool in
            switch tool {
            case .outline:
                OutlineSheet(source: draft) { line in
                    // Once the sheet has gone, so the editor can take focus.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        handle.jump(toLine: line)
                    }
                }
            case .find:
                FindReplaceSheet(session: session, beforeReplace: { commitNow() },
                                 afterReplace: { draft = file?.source ?? draft })
            case .diff:
                DiffSheet(title: L("What changed"), old: opened, new: draft)
            case .debug:
                DebugSheet(world: worldWithDraft, fileName: file?.name ?? "")
            }
        }
        .onAppear {
            draft = file?.source ?? ""
            opened = draft
            // One undo step for the whole visit, not one per keystroke.
            session.edit { $0.beginGesture() }
            check()
        }
        .onDisappear {
            commitNow()
            session.edit { $0.endGesture() }
        }
    }

    private var moreMenu: some View {
        Menu {
            Menu {
                ForEach(ScriptSnippets.all) { snippet in
                    Button {
                        handle.replace(with: snippet.code + "\n")
                    } label: {
                        Label(snippet.title, systemImage: snippet.symbolName)
                    }
                }
            } label: {
                Label(L("Insert a snippet"), systemImage: "text.badge.plus")
            }
            Button {
                draft = ScriptFormatter.format(draft)
            } label: {
                Label(L("Tidy the indents"), systemImage: "text.alignleft")
            }
            Button {
                tool = .outline
            } label: {
                Label(L("Outline"), systemImage: "list.bullet.indent")
            }
            Button {
                commitNow()
                tool = .find
            } label: {
                Label(L("Find in every file"), systemImage: "magnifyingglass")
            }
            Button {
                tool = .diff
            } label: {
                Label(L("What changed"), systemImage: "plus.forwardslash.minus")
            }
            Divider()
            Button {
                commitNow()
                tool = .debug
            } label: {
                Label(L("Debug with breakpoints"), systemImage: "ladybug")
            }
            Button {
                testRun(robots: true)
            } label: {
                Label(L("Test run with robots"), systemImage: "figure.walk.motion")
            }
            Divider()
            Button {
                if let file {
                    ScriptLibraryStore.save(ScriptFile(name: file.name, source: draft))
                    note = L("Saved “{}” to your library.", file.name)
                }
            } label: {
                Label(L("Save to my library"), systemImage: "books.vertical")
            }
            Picker(selection: $themeName) {
                ForEach(CodeTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme.rawValue)
                }
            } label: {
                Label(L("Colours"), systemImage: "paintpalette")
            }
            .pickerStyle(.menu)
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
        } label: {
            Label(L("More"), systemImage: "ellipsis.circle")
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            if report != nil {
                HStack(spacing: 8) {
                    Picker(L("Show"), selection: $logFilter) {
                        ForEach(LogFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    AbloxTextField(L("Search the log"), text: $logSearch)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .padding(6)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let note {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.success)
                    }
                    if let report {
                        Text(L("Test run: two players, nobody pressing anything"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Ablox.Palette.inkMuted)
                        TestReportView(report: report, filter: logFilter, search: logSearch, onProblem: jump(to:))
                        if report.notes.isEmpty, report.output.isEmpty, report.robotNotes.isEmpty, report.isClean {
                            Text(L("It ran without errors, but did nothing anyone could see."))
                                .font(.footnote)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                        }
                    } else {
                        if problems.isEmpty {
                            Label(L("No problems found"), systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Ablox.Palette.success)
                                .font(.subheadline.weight(.semibold))
                        }
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                            ProblemRow(problem: problem, onTap: jump(to:))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    // MARK: Actions

    /// Goes to a problem's line when it is in this file.
    private func jump(to problem: ScriptError) {
        guard isHere(problem), problem.line > 0 else { return }
        handle.jump(toLine: problem.line)
    }

    private func check() {
        commitNow()
        report = nil
        note = nil
        problems = GameRuntime.check(filesWithDraft)
    }

    private func testRun(robots: Bool) {
        commitNow()
        note = nil
        let result = GameRuntime.testRun(world: worldWithDraft, seconds: 5, robots: robots)
        problems = result.problems
        report = result
    }

    /// Saves after a pause in typing, so co-editors see the script without
    /// being sent every keystroke, and checks it again so the underlines
    /// follow the code.
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            commitNow()
            if report == nil { problems = GameRuntime.check(filesWithDraft) }
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        guard let file, draft != file.source else { return }
        session.edit { $0.updateScript(fileID, source: draft) }
    }
}

/// The editor's sheets.
enum ScriptEditorTool: String, Identifiable {
    case outline, find, diff, debug
    var id: String { rawValue }
}

/// A problem, tappable to go to its line.
struct ProblemRow: View {
    let problem: ScriptError
    var onTap: ((ScriptError) -> Void)?

    var body: some View {
        Button {
            onTap?(problem)
        } label: {
            Label {
                Text(verbatim: problem.description)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(problem.kind == .syntax ? Ablox.Palette.danger : Ablox.Palette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}

/// Everything a script can use, grouped, beside the editor, with a search
/// box; the plus puts an entry in at the cursor.
struct ScriptReferenceView: View {
    var onInsert: ((String) -> Void)?
    @State private var query = ""

    init(onInsert: ((String) -> Void)? = nil) {
        self.onInsert = onInsert
    }

    /// A section with the entries that match the search.
    private struct Match: Identifiable {
        let section: ScriptReference.Section
        let entries: [ScriptReference.Entry]
        var id: ScriptReference.Section.ID { section.id }
    }

    private var matches: [Match] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return ScriptReference.sections.compactMap { section in
            let entries = words.isEmpty ? section.entries : section.entries.filter {
                $0.code.localizedCaseInsensitiveContains(words) || $0.explanation.localizedCaseInsensitiveContains(words)
            }
            return entries.isEmpty ? nil : Match(section: section, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ablox.Palette.inkFaint)
                AbloxTextField(L("Search the reference"), text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.callout)
            }
            .padding(10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding([.horizontal, .top], 12)

            List {
                if matches.isEmpty {
                    Text(L("Nothing matches that."))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
                ForEach(matches) { match in
                    Section {
                        ForEach(match.entries) { entry in
                            HStack(alignment: .top, spacing: 6) {
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
                                Spacer(minLength: 0)
                                if let onInsert {
                                    Button {
                                        onInsert(entry.code)
                                    } label: {
                                        Image(systemName: "plus.circle")
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(L("Put it in the code"))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Label(match.section.title, systemImage: match.section.symbolName)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}
