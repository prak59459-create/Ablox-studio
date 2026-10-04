import SwiftUI

// The script editor's helpers: suggestions over the keyboard, the outline,
// find and replace across files, what changed, breakpoints, a library of
// the player's own scripts, pushing to GitHub, and the block editor.

// MARK: - Suggestions

struct CompletionBar: View {
    @ObservedObject var handle: CodeEditorHandle
    let source: String
    let blockNames: [String]

    var body: some View {
        let context = ScriptCompletion.context(in: handle.text, cursor: handle.cursor)
        let suggestions = handle.cursorRevision >= 0
            ? ScriptCompletion.suggestions(for: context, source: source, blockNames: blockNames) : []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if suggestions.isEmpty {
                    Text(L("Suggestions appear here as you type."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
                ForEach(suggestions) { suggestion in
                    Button {
                        handle.replace(context.range, with: suggestion.text)
                    } label: {
                        HStack(spacing: 4) {
                            Text(suggestion.text).font(.system(.caption, design: .monospaced).weight(.semibold))
                            Text(suggestion.detail).font(.system(size: 9)).foregroundStyle(Ablox.Palette.inkFaint)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 36)
    }
}

// MARK: - Outline

struct OutlineSheet: View {
    let source: String
    var onJump: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ScriptOutline.items(in: source)) { item in
                Button {
                    onJump(item.line)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: item.kind == .event ? "bolt.fill" : item.kind == .function ? "function" : "character.cursor.ibeam")
                            .foregroundStyle(item.kind == .event ? Ablox.Palette.success : Ablox.Palette.accent)
                        Text(item.name).font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text(L("line {}", item.line)).font(.caption).foregroundStyle(Ablox.Palette.inkFaint)
                    }
                }
            }
            .overlay {
                if ScriptOutline.items(in: source).isEmpty {
                    Text(L("No handlers or functions yet.")).foregroundStyle(Ablox.Palette.inkMuted)
                }
            }
            .navigationTitle(L("Outline"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Notes to self, and going to a line

/// The comments with TODO, FIXME, あとで or メモ in the open file.
struct NotesSheet: View {
    let file: ScriptFile
    var onJump: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let notes = ScriptLineTools.notes(in: [file])
        NavigationStack {
            List(notes) { note in
                Button {
                    onJump(note.line)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "checklist").foregroundStyle(Ablox.Palette.warning)
                        Text(note.preview).font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Text(L("line {}", note.line)).font(.caption).foregroundStyle(Ablox.Palette.inkFaint)
                    }
                }
            }
            .overlay {
                if notes.isEmpty {
                    Text(L("No notes. Write “-- TODO: …” in a comment to leave one."))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .navigationTitle(L("TODO notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}

struct GoToLineSheet: View {
    let lines: Int
    var onJump: (Int) -> Void
    @State private var text = ""

    var body: some View {
        TextPromptSheet(title: L("Go to line"), message: L("1 to {}", lines), placeholder: "1",
                        confirm: L("Go"), text: $text) {
            let digits = text.filter(\.isNumber)
            if let line = Int(digits) { onJump(min(max(1, line), lines)) }
        }
    }
}

// MARK: - Find and replace, in every file

struct FindReplaceSheet: View {
    @ObservedObject var session: StudioSession
    /// Commits the open file's draft before replacing, and reloads it after.
    var beforeReplace: () -> Void
    var afterReplace: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AbloxTextField(L("Find"), text: $query)
                    AbloxTextField(L("Replace with"), text: $replacement)
                    Toggle(L("Match capitals"), isOn: $caseSensitive)
                    Button(L("Replace all")) {
                        beforeReplace()
                        let result = ScriptSearch.replaceAll(query, with: replacement, in: session.document.world.scripts,
                                                             caseSensitive: caseSensitive)
                        session.edit { $0.setScripts(result.files) }
                        afterReplace()
                        note = L("Replaced {} times. Undo takes it back.", result.count)
                    }
                    .disabled(query.isEmpty)
                    if let note { Text(note).font(.caption).foregroundStyle(Ablox.Palette.success) }
                }
                Section(L("Found")) {
                    ForEach(ScriptSearch.find(query, in: session.document.world.scripts, caseSensitive: caseSensitive)) { match in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(match.fileName):\(match.line)").font(.caption.weight(.semibold)).foregroundStyle(Ablox.Palette.accent)
                            Text(match.preview).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle(L("Find in every file"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - What changed

struct DiffSheet: View {
    let title: String
    let old: String
    let new: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                changes(TextDiff.lines(from: old, to: new))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func changes(_ lines: [DiffLine]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if !lines.contains(where: { $0.kind != .same }) {
                Text(L("Nothing has changed.")).foregroundStyle(Ablox.Palette.inkMuted).padding()
            }
            ForEach(lines) { line in
                row(line)
            }
        }
    }

    // A line and its colour in plain typed steps: written inline, the
    // nested choices made this one of the slowest views to compile.
    private func row(_ line: DiffLine) -> some View {
        let marker: String
        let shade: Color
        switch line.kind {
        case .added:
            marker = "+ "
            shade = Color.green.opacity(0.18)
        case .removed:
            marker = "− "
            shade = Color.red.opacity(0.18)
        case .same:
            marker = "  "
            shade = .clear
        }
        return Text(verbatim: marker + line.text)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(shade)
    }
}

// MARK: - Breakpoints

struct DebugSheet: View {
    let world: WorldDocument
    let fileName: String
    @Environment(\.dismiss) private var dismiss

    @State private var lines = ""
    @State private var seconds = 5.0
    @State private var robots = true
    @State private var report: ScriptTestReport?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AbloxTextField(L("Lines to stop at, like 4, 12"), text: $lines)
                    Stepper(L("Run for {} seconds", Int(seconds)), value: $seconds, in: 1...30)
                    Toggle(L("Robots play"), isOn: $robots)
                    Button {
                        let points = lines.split(whereSeparator: { $0 == "," || $0 == " " })
                            .compactMap { Int($0) }.map { ScriptBreakpoint(file: fileName, line: $0) }
                        report = GameRuntime.testRun(world: world, seconds: seconds, breakpoints: points, robots: robots)
                    } label: {
                        Label(L("Run"), systemImage: "play.fill")
                    }
                } footer: {
                    Text(L("When one of these lines runs, the variables there are written down and the game carries on — nothing freezes."))
                }
                if let report {
                    Section(L("Results")) {
                        TestReportView(report: report)
                        if report.hits.isEmpty {
                            Text(L("None of those lines ran.")).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
                        }
                    }
                }
            }
            .navigationTitle(L("Debug {}", fileName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - My script library

/// Scripts saved to use again in other worlds, on this iPad.
enum ScriptLibraryStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScriptLibrary", isDirectory: true)
    }

    static func all() -> [ScriptFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == ScriptFile.fileExtension }.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { ScriptFile(name: url.lastPathComponent, source: $0) }
        }
        .sorted { $0.name < $1.name }
    }

    static func save(_ file: ScriptFile) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? file.source.write(to: directory.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
    }

    static func delete(_ file: ScriptFile) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.name))
    }
}

struct ScriptLibrarySheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var files = ScriptLibraryStore.all()

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty {
                    Text(L("Nothing here yet. In the script editor, More → Save to my library keeps a file for other worlds."))
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
                ForEach(files) { file in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(file.name).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            Text(L("{} lines", file.source.split(separator: "\n", omittingEmptySubsequences: false).count))
                                .font(.caption).foregroundStyle(Ablox.Palette.inkFaint)
                        }
                        Spacer()
                        Button(L("Add to this world")) {
                            session.edit { _ = $0.addScript(named: String(file.name.dropLast(ScriptFile.fileExtension.count + 1)), source: file.source) }
                            dismiss()
                        }
                        .buttonStyle(NeonButtonStyle(.primary))
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            ScriptLibraryStore.delete(file)
                            files = ScriptLibraryStore.all()
                        } label: {
                            Label(L("Delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(L("My script library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Pushing to GitHub

/// Sends the world's `.absc` files to its GitHub folder with a personal
/// access token (kept in the keychain), through GitHub's contents API.
enum GitHubPusher {
    static let tokenAccount = "github.token"

    static var token: String? {
        Keychain.read(account: tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setToken(_ token: String?) {
        if let token, !token.isEmpty {
            Keychain.write(Data(token.utf8), account: tokenAccount)
        } else {
            Keychain.delete(account: tokenAccount)
        }
    }

    /// Returns how many files were sent.
    static func push(_ files: [ScriptFile], to source: ScriptSource, token: String, message: String) async throws -> Int {
        var sent = 0
        for file in files where file.isEnabled {
            let path = (source.cleanFolder.isEmpty ? "" : source.cleanFolder + "/") + file.name
            let encodedPath = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            guard let url = URL(string: "https://api.github.com/repos/\(source.repository)/contents/\(encodedPath)") else { continue }
            // The file's current version, which an update must name.
            var lookup = URLRequest(url: URL(string: url.absoluteString + "?ref=" + (source.branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source.branch))!)
            lookup.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            lookup.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (existing, response) = try await URLSession.shared.data(for: lookup)
            let sha = (response as? HTTPURLResponse)?.statusCode == 200 ? (try? JSONValue(data: existing))?["sha"].string : nil

            var body: [String: JSONValue] = [
                "message": .string(message),
                "content": .string(Data(file.source.utf8).base64EncodedString()),
                "branch": .string(source.branch)
            ]
            if let sha { body["sha"] = .string(sha) }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.httpBody = JSONValue.object(body).data
            let (answer, result) = try await URLSession.shared.data(for: request)
            let status = (result as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let reason = (try? JSONValue(data: answer))?["message"].string ?? "HTTP \(status)"
                throw PushError(message: L("GitHub refused {}: {}", file.name, reason))
            }
            sent += 1
        }
        return sent
    }

    struct PushError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

struct GitHubPushSheet: View {
    @ObservedObject var session: StudioSession
    @Environment(\.dismiss) private var dismiss

    @State private var token = GitHubPusher.token ?? ""
    @State private var message = "Update scripts from Ablox Studio"
    @State private var working = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                if let source = session.document.world.scriptSource {
                    Section {
                        LabeledContent(L("Repository"), value: source.repository)
                        LabeledContent(L("Branch"), value: source.branch)
                        LabeledContent(L("Folder"), value: source.cleanFolder.isEmpty ? "/" : source.cleanFolder)
                        AbloxTextField(L("Change message"), text: $message)
                    }
                    Section {
                        SecureField(L("Personal access token"), text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            if let text = UIPasteboard.general.string { token = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        } label: {
                            Label(L("Paste"), systemImage: "doc.on.clipboard")
                        }
                    } footer: {
                        Text(L("Make a fine-grained token on github.com (Settings → Developer settings) with Contents: read and write for this repository only. It is kept in this iPad's keychain."))
                    }
                    Section {
                        Button {
                            push(source)
                        } label: {
                            if working { ProgressView() } else { Label(L("Push {} files", session.document.world.scripts.filter(\.isEnabled).count), systemImage: "arrow.up.circle.fill") }
                        }
                        .disabled(working || token.isEmpty)
                        if let result { Text(result).font(.caption) }
                        if GitHubPusher.token != nil {
                            Button(L("Forget the token"), role: .destructive) {
                                GitHubPusher.setToken(nil)
                                token = ""
                            }
                        }
                    }
                } else {
                    Text(L("Connect this world to a GitHub folder first (Script → GitHub)."))
                }
            }
            .navigationTitle(L("Push to GitHub"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func push(_ source: ScriptSource) {
        working = true
        result = nil
        GitHubPusher.setToken(token)
        let files = session.document.world.scripts
        Task { @MainActor in
            do {
                let count = try await GitHubPusher.push(files, to: source, token: token, message: message)
                result = L("Pushed {} files.", count)
            } catch {
                result = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Programming with blocks

struct BlockProgramEditor: View {
    @ObservedObject var session: StudioSession
    let fileID: UUID
    var onEditAsCode: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var program = BlockProgram()
    @State private var showCode = false

    private var partNames: [String] { session.document.world.blocks.map(\.name).sorted() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($program.cards) { $card in
                        cardView($card)
                    }
                    Menu {
                        ForEach(BlockProgram.Trigger.allCases) { trigger in
                            Button {
                                program.cards.append(BlockProgram.Card(trigger: trigger, value: trigger == .every ? "1" : ""))
                            } label: {
                                Label(trigger.displayName, systemImage: trigger.symbolName)
                            }
                        }
                    } label: {
                        Label(L("Add a “when”"), systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))

                    if showCode {
                        Text(program.source)
                            .font(.system(.caption, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    }
                    let problems = GameRuntime.check([ScriptFile(name: "blocks", source: program.fileSource)])
                    if !problems.isEmpty {
                        ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                            Text(problem.description).font(.caption).foregroundStyle(Ablox.Palette.warning)
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle(L("Blocks"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { save(); dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(showCode ? L("Hide the code") : L("Show the code")) { showCode.toggle() }
                    Button(L("Edit as code")) {
                        save()
                        dismiss()
                        onEditAsCode()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let file = session.document.world.scripts.first(where: { $0.id == fileID }) {
                program = BlockProgram(file: file) ?? BlockProgram()
            }
        }
    }

    private func save() {
        session.edit { $0.updateScript(fileID, source: program.fileSource) }
    }

    // A card in parts, each type-checked on its own: as one expression it
    // was among the slowest things in the editor to compile.
    private func cardView(_ card: Binding<BlockProgram.Card>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(card)
            cardInput(card)
            ForEach(card.steps) { $step in
                stepView($step) {
                    card.wrappedValue.steps.removeAll { $0.id == step.id }
                }
            }
            addStepMenu(card)
        }
        .padding(14)
        .background(Ablox.Palette.accentDeep.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ablox.Palette.accent.opacity(0.3)))
    }

    private func cardHeader(_ card: Binding<BlockProgram.Card>) -> some View {
        let trigger = card.wrappedValue.trigger
        let id = card.wrappedValue.id
        return HStack {
            Label(trigger.displayName, systemImage: trigger.symbolName)
                .font(.headline)
            Spacer()
            Button(role: .destructive) {
                program.cards.removeAll { $0.id == id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ablox.Palette.danger)
        }
    }

    @ViewBuilder private func cardInput(_ card: Binding<BlockProgram.Card>) -> some View {
        if let asks = card.wrappedValue.trigger.asks {
            if card.wrappedValue.trigger == .touch {
                Picker(asks, selection: card.value) {
                    Text(L("Any part")).tag("")
                    ForEach(partNames, id: \.self) { Text($0).tag($0) }
                }
            } else {
                AbloxTextField(asks, text: card.value)
                    .padding(8)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func addStepMenu(_ card: Binding<BlockProgram.Card>) -> some View {
        Menu {
            ForEach(BlockProgram.Action.allCases) { action in
                Button(action.displayName) {
                    card.wrappedValue.steps.append(BlockProgram.Step(action: action))
                }
            }
        } label: {
            Label(L("Add a “do”"), systemImage: "plus")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func stepView(_ step: Binding<BlockProgram.Step>, remove: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(Ablox.Palette.inkFaint)
            Text(step.wrappedValue.action.displayName).font(.subheadline)
            if let asks = step.wrappedValue.action.asksText {
                AbloxTextField(asks, text: step.text)
                    .padding(6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let asks = step.wrappedValue.action.asksNumber {
                Stepper("\(asks): \(ScriptValue.format(step.wrappedValue.number))", value: step.number, in: 0...100, step: 1)
                    .font(.caption)
            }
            if step.wrappedValue.action.asksPart {
                Picker(L("Part"), selection: step.part) {
                    Text(L("Choose a part")).tag("")
                    ForEach(partNames, id: \.self) { Text($0).tag($0) }
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ablox.Palette.inkFaint)
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
