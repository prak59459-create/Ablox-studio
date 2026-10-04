import SwiftUI
import UniformTypeIdentifiers

// What the player sees of `AppUpdater`: a banner in the menu when a new
// version is out or already downloaded, a card in Settings, the sheet that
// hands the new project to Swift Playgrounds, and what changed after it.
// Shared by Ablox and Ablox Studio (see `scripts/sync-core.sh` in the
// Studio repository), which update the same way.

/// A strip across the top of the menu: there is something newer, it is on
/// its way, or it is in the project and waiting for the project to be opened
/// again.
public struct UpdateBanner: View {
    @ObservedObject private var updater: AppUpdater
    private let install: () -> Void
    @State private var hidden = false

    public init(updater: AppUpdater, install: @escaping () -> Void) {
        self.updater = updater
        self.install = install
    }

    public var body: some View {
        if !hidden, let title {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                action
                if !updater.isRequired || updater.waitingForReopen != nil {
                    Button {
                        withAnimation { hidden = true }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Ablox.Palette.inkFaint)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Later"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal, Ablox.Metrics.gutter)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Nil: nothing to say.
    private var title: String? {
        if let waiting = updater.waitingForReopen {
            let version = UpdateLabels.version(of: waiting)
            return updater.stillOld ? L("Still the old version") : L("{} {} is in the project", updater.release.app, version)
        }
        guard let latest = updater.latest, updater.shouldOffer || updater.phase == .ready else { return nil }
        return L("{} {} is out", updater.release.app, latest.version.description)
    }

    private var symbol: String {
        if updater.waitingForReopen != nil { return updater.stillOld ? "arrow.clockwise.circle.fill" : "checkmark.seal.fill" }
        return updater.isRequired ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.app.fill"
    }

    private var tint: Color {
        if updater.waitingForReopen != nil { return updater.stillOld ? Ablox.Palette.warning : Ablox.Palette.success }
        return updater.isRequired ? Ablox.Palette.warning : Ablox.Palette.accent
    }

    private var detail: String {
        if updater.waitingForReopen != nil {
            return updater.stillOld
                ? L("Swift Playgrounds is still running the old one. Close the project and open it again.")
                : L("Stop it with ■, close the project and open it again: then it is the new version.")
        }
        if updater.inPlace == .working { return L("Writing the new files…") }
        if case let .failed(message) = updater.inPlace { return message }
        switch updater.phase {
        case .downloading: return L("Downloading…")
        case .unpacking: return L("Getting it ready…")
        case .ready:
            return updater.linkedProject != nil ? L("Downloaded. One tap puts it in.") : L("Downloaded and ready. Two taps and you have it.")
        case let .failed(message): return message
        default:
            return updater.isRequired
                ? L("Friends with the new version cannot play with this one until it updates.")
                : (updater.latest?.notes(for: currentLanguageCode).first ?? L("A newer version of this app is ready to download."))
        }
    }

    @ViewBuilder private var action: some View {
        if updater.isBusy || updater.inPlace == .working {
            ProgressView().tint(Ablox.Palette.accent)
        } else if updater.waitingForReopen != nil {
            Button(L("How"), action: install)
                .buttonStyle(NeonButtonStyle(.secondary))
        } else if updater.linkedProject != nil {
            Button(L("Update")) { Task { await updater.updateNow() } }
                .buttonStyle(NeonButtonStyle(.primary))
        } else if updater.phase == .ready {
            Button(L("Install"), action: install)
                .buttonStyle(NeonButtonStyle(.primary))
        } else {
            // Opens the steps while it downloads.
            Button(L("Update")) {
                install()
                Task { await updater.download() }
            }
            .buttonStyle(NeonButtonStyle(.primary))
        }
    }
}

/// "2.1-10" → "2.1".
enum UpdateLabels {
    static func version(of label: String) -> String {
        String(label.split(separator: "-").first ?? Substring(label))
    }
}

/// Settings: which version this is, whether there is a newer one, and
/// whether to look, download and put it in by itself.
public struct UpdateSettingsCard: View {
    @ObservedObject private var updater: AppUpdater
    private let install: () -> Void
    @State private var choosingProject = false
    @State private var linkProblem: String?

    public init(updater: AppUpdater, install: @escaping () -> Void) {
        self.updater = updater
        self.install = install
    }

    public var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(L("Updates"), systemImage: "arrow.triangle.2.circlepath")

                HStack(spacing: 10) {
                    Text(L("This is version {}", "\(updater.release.version) (\(updater.release.build))"))
                        .font(.subheadline.weight(.semibold))
                    statusBadge
                    Spacer()
                }

                if let latest = updater.latest, updater.availability != .current {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("New in {}", latest.version.description))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Ablox.Palette.accent)
                        ForEach(Array(latest.notes(for: currentLanguageCode).enumerated()), id: \.offset) { _, line in
                            Label(line, systemImage: "sparkle")
                                .font(.caption)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                        }
                    }
                }

                if updater.waitingForReopen != nil {
                    ReopenGuide(updater: updater)
                }

                HStack(spacing: 10) {
                    if updater.availability != .current, updater.waitingForReopen == nil {
                        if updater.linkedProject != nil {
                            Button { Task { await updater.updateNow() } } label: {
                                Label(L("Update now"), systemImage: "bolt.fill")
                            }
                            .buttonStyle(NeonButtonStyle(.primary))
                            .disabled(updater.isBusy || updater.inPlace == .working)
                        } else if updater.phase == .ready {
                            Button(action: install) {
                                Label(L("Install"), systemImage: "square.and.arrow.down.on.square")
                            }
                            .buttonStyle(NeonButtonStyle(.primary))
                        } else {
                            Button {
                                install()
                                Task { await updater.download() }
                            } label: {
                                Label(L("Update"), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(NeonButtonStyle(.primary))
                            .disabled(updater.isBusy)
                        }
                    }
                    Button { Task { await updater.check() } } label: {
                        Label(L("Check now"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                    .disabled(updater.isBusy)
                }

                if case let .failed(message) = updater.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Ablox.Palette.line)

                inPlaceSection

                Divider().background(Ablox.Palette.line)

                Toggle(isOn: $updater.checksAutomatically) {
                    label(L("Look for updates by itself"), L("When the app opens, and every hour while it is open."))
                }
                .tint(Ablox.Palette.accent)
                Toggle(isOn: $updater.downloadsAutomatically) {
                    label(L("Download them by itself"), L("On Wi-Fi only, so it is ready when you are."))
                }
                .tint(Ablox.Palette.accent)
                .disabled(!updater.checksAutomatically)

                if let checked = updater.lastChecked {
                    Text(L("Last looked {}", checked.formatted(.relative(presentation: .named))))
                        .font(.caption2)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                }
            }
        }
    }

    /// Choosing the project on this iPad, so updates go straight into it.
    private var inPlaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label(L("Update the project already on this iPad"),
                  L("Only the files that changed are written into it, so Swift Playgrounds builds just those. A version sent over as a new project is built whole, which takes much longer."))
            ProjectLinkRow(updater: updater, problem: $linkProblem) { choosingProject = true }
            Toggle(isOn: $updater.installsAutomatically) {
                label(L("Put new versions in by themselves"), L("As soon as one is downloaded, it goes into the chosen project. Then close the project and open it again."))
            }
            .tint(Ablox.Palette.accent)
            .disabled(updater.linkedProject == nil)
            InPlaceStatusLine(updater: updater)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    AbloxTextField(L("Branch to follow (empty: released versions)"), text: $updater.followedBranch)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.callout.monospaced())
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button { Task { await updater.pullLatest() } } label: {
                        Label(L("Take the latest now"), systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(NeonButtonStyle(.primary))
                    .disabled(updater.linkedProject == nil || updater.inPlace == .working)
                    Text(L("Takes the project as it is on that branch right now, whatever its version number, and puts it straight into the chosen project."))
                        .font(.caption2)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text(L("For trying versions before they are out"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
            .tint(Ablox.Palette.accent)
        }
        .fileImporter(isPresented: $choosingProject, allowedContentTypes: ProjectLinkRow.types) { result in
            guard case let .success(url) = result else { return }
            linkProblem = updater.linkProject(at: url)
            // Chosen: if there is a version waiting, in it goes.
            if linkProblem == nil, updater.availability != .current {
                Task { await updater.updateNow() }
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch updater.phase {
        case .checking: Badge(L("Looking…"), color: Ablox.Palette.inkMuted)
        case .downloading: Badge(L("Downloading…"))
        case .unpacking: Badge(L("Getting it ready…"))
        case .ready: Badge(L("Ready to install"), color: Ablox.Palette.success, systemImage: "checkmark")
        default:
            if updater.availability == .current {
                Badge(L("Up to date"), color: Ablox.Palette.success, systemImage: "checkmark")
            } else {
                Badge(L("Update available"), color: updater.isRequired ? Ablox.Palette.warning : Ablox.Palette.accent)
            }
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ablox.Palette.ink)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Updating, step by step. With the project chosen it is one button; the
/// first time, it is choosing the project once. A new project (the slow way,
/// built whole) is kept for when that does not work.
public struct UpdateInstallSheet: View {
    @ObservedObject private var updater: AppUpdater
    /// A backup of everything, made as the sheet opens.
    private let backup: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var choosingProject = false
    @State private var linkProblem: String?
    @State private var exporting = false
    @State private var exportMessage: String?

    public init(updater: AppUpdater, backup: URL?) {
        self.updater = updater
        self.backup = backup
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Ablox.Palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Install {} {}", updater.release.app, updater.latest?.version.description ?? ""))
                            .font(.title2.weight(.bold))
                        Text(L("Everything you have stays."))
                            .font(.subheadline)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                    }
                }

                if updater.waitingForReopen != nil {
                    ReopenGuide(updater: updater)
                } else {
                    progressLine
                    if updater.linkedProject != nil {
                        oneTap
                    } else {
                        firstTime
                    }
                }

                newProjectWay

                if let backup {
                    Divider().background(Ablox.Palette.line)
                    Text(L("A backup of everything was made just now. Keep a copy in Files too, to be extra safe:"))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    ShareLink(item: backup) {
                        Label(L("Save the backup"), systemImage: "externaldrive.badge.checkmark")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                }

                Button(L("Close")) { dismiss() }
                    .buttonStyle(NeonButtonStyle(.secondary))
            }
            .padding(28)
        }
        .presentationDetents([.large])
        .fileImporter(isPresented: $choosingProject, allowedContentTypes: ProjectLinkRow.types) { result in
            guard case let .success(url) = result else { return }
            linkProblem = updater.linkProject(at: url)
            if linkProblem == nil { Task { await updater.updateNow() } }
        }
        .fileExporter(isPresented: $exporting, document: PackageExportDocument(folder: updater.stagedPackage),
                      contentType: ProjectLinkRow.packageType, defaultFilename: exportName) { result in
            switch result {
            case .success: exportMessage = L("Saved. Open it in Swift Playgrounds and press ▶︎.")
            case .failure: exportMessage = L("It could not be saved there. Try the Playgrounds folder in Files.")
            }
        }
    }

    /// Downloading, getting ready, or what went wrong.
    @ViewBuilder private var progressLine: some View {
        switch updater.phase {
        case .downloading, .unpacking, .checking:
            HStack(spacing: 10) {
                ProgressView().tint(Ablox.Palette.accent)
                Text(updater.phase == .unpacking ? L("Getting it ready…") : L("Downloading…"))
                    .font(.subheadline)
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Ablox.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button { Task { await updater.download() } } label: {
                    Label(L("Try again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(NeonButtonStyle(.secondary))
            }
        default:
            EmptyView()
        }
    }

    /// The project is chosen: one button does the rest.
    private var oneTap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { Task { await updater.updateNow() } } label: {
                Label(L("Update now"), systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
            .disabled(updater.isBusy || updater.inPlace == .working)
            Text(L("Only the files that changed go into {}, so the next build is quick.", updater.linkedProject ?? updater.release.package))
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            InPlaceStatusLine(updater: updater)
            ProjectLinkRow(updater: updater, problem: $linkProblem) { choosingProject = true }
        }
    }

    /// Not chosen yet: how to choose the project, once.
    private var firstTime: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Once only: choose the project"))
                .font(.headline)
            UpdateStep(number: 1, text: L("Tap the button below. Files opens."))
            UpdateStep(number: 2, text: L("Open the Playgrounds folder (On My iPad or iCloud Drive)."))
            UpdateStep(number: 3, text: L("Choose {} and tap Open.", updater.release.package))
            ProjectLinkRow(updater: updater, problem: $linkProblem) { choosingProject = true }
            Text(L("After that, this and every new version goes in by itself."))
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Ablox.Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The slow way, kept for when choosing the project does not work: the
    /// whole new project, built from the start.
    private var newProjectWay: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let package = updater.stagedPackage {
                    UpdateStep(number: 1, text: L("Save it into the Playgrounds folder in Files, or send it to Swift Playgrounds."))
                    HStack(spacing: 10) {
                        Button { exporting = true } label: {
                            Label(L("Save to Files"), systemImage: "folder")
                        }
                        .buttonStyle(NeonButtonStyle(.primary))
                        ShareLink(item: package) {
                            Label(L("Send to Swift Playgrounds"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(NeonButtonStyle(.secondary))
                    }
                    if let exportMessage {
                        Text(exportMessage)
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    UpdateStep(number: 2, text: L("In Swift Playgrounds, open the new {} and press ▶︎. It is built whole, so the first time takes longer.", updater.release.app))
                    UpdateStep(number: 3, text: L("Your worlds, coins and saved games carry over. When the new one runs, you can delete the old one."))
                } else {
                    Text(L("This appears when the download has finished."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
            }
            .padding(.top, 8)
        } label: {
            Text(L("Not working? Install it as a new project"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Ablox.Palette.inkMuted)
        }
        .tint(Ablox.Palette.accent)
    }

    /// "Ablox" when Files adds ".swiftpm" itself, the whole name otherwise.
    private var exportName: String {
        ProjectLinkRow.packageType.preferredFilenameExtension == "swiftpm"
            ? (updater.release.package as NSString).deletingPathExtension
            : updater.release.package
    }
}

/// After a version went into the project: Swift Playgrounds keeps a project
/// as it was when it was opened, so it has to be opened again.
struct ReopenGuide: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("The new version is in the project"), systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Ablox.Palette.success)
            if updater.stillOld {
                Text(L("This is still the old version: Swift Playgrounds keeps a project as it was when it was opened."))
                    .font(.subheadline)
                    .foregroundStyle(Ablox.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            UpdateStep(number: 1, text: L("Stop the app with ■ in Swift Playgrounds."))
            UpdateStep(number: 2, text: L("Close the project: go back to the list of your projects."))
            UpdateStep(number: 3, text: L("Open {} again and press ▶︎. Only the changed files are built.", updater.release.app))
            Text(L("Still the old one? Close Swift Playgrounds completely (swipe it up in the app switcher) and open it again."))
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if updater.stillOld {
                Button(L("Got it")) { updater.dismissReopenReminder() }
                    .buttonStyle(NeonButtonStyle(.secondary))
            }
        }
        .padding(16)
        .background(Ablox.Palette.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One numbered step.
struct UpdateStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 30, height: 30)
                .background(Circle().fill(Ablox.Palette.accent.opacity(0.2)))
                .foregroundStyle(Ablox.Palette.accent)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The downloaded project as a document, so "Save to Files" can put it
/// straight into the Playgrounds folder (sharing a folder does not always
/// offer Swift Playgrounds).
struct PackageExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [ProjectLinkRow.packageType] }

    let folder: URL?

    init(folder: URL?) {
        self.folder = folder
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: folder, options: .immediate)
    }
}

/// Which project updates go into, and the button to choose it.
struct ProjectLinkRow: View {
    @ObservedObject var updater: AppUpdater
    @Binding var problem: String?
    let choose: () -> Void

    /// A Swift Playgrounds project is a package (a folder shown as one
    /// file); the Playgrounds folder around it will do too.
    static var types: [UTType] {
        [.folder, .package] + [UTType(filenameExtension: "swiftpm")].compactMap { $0 }
    }

    /// A Swift Playgrounds project, for saving one to Files.
    static var packageType: UTType {
        UTType(filenameExtension: "swiftpm", conformingTo: .package) ?? .package
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let project = updater.linkedProject {
                    Label(project, systemImage: "folder.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ablox.Palette.success)
                    Spacer()
                    Button(L("Choose again"), action: choose)
                        .font(.caption.weight(.semibold))
                    Button(L("Forget"), role: .destructive) { updater.unlinkProject() }
                        .font(.caption.weight(.semibold))
                } else {
                    Button(action: choose) {
                        Label(L("Choose the project in Files"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                }
            }
            if updater.linkedProject == nil {
                Text(L("In Files, open the Playgrounds folder and choose {}.", updater.release.package))
                    .font(.caption2)
                    .foregroundStyle(Ablox.Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// How putting a version straight into the project went.
struct InPlaceStatusLine: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        switch updater.inPlace {
        case .idle:
            EmptyView()
        case .working:
            Label(L("Writing the new files…"), systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.inkMuted)
        case let .done(written, deleted):
            Label(doneText(written: written, deleted: deleted), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.success)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func doneText(written: Int, deleted: Int) -> String {
        if written == 0 && deleted == 0 {
            return L("The project is already this version.")
        }
        return L("{} files updated, {} removed. Go back to Swift Playgrounds and press ▶︎: only these are built again.", written, deleted)
    }
}

/// Shown once, the first time a new version runs.
public struct WhatsNewSheet: View {
    private let manifest: UpdateManifest
    @Environment(\.dismiss) private var dismiss

    public init(manifest: UpdateManifest) {
        self.manifest = manifest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(Ablox.Palette.accent)
                Text(L("Updated to {}", manifest.version.description))
                    .font(.title2.weight(.bold))
            }
            let notes = manifest.notes(for: currentLanguageCode)
            if notes.isEmpty {
                Text(L("Everything you had is still here."))
                    .foregroundStyle(Ablox.Palette.inkMuted)
            } else {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Ablox.Palette.ink)
                }
            }
            Button(L("Let's go")) { dismiss() }
                .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
                .padding(.top, 6)
        }
        .padding(28)
        .presentationDetents([.medium, .large])
    }
}

/// "ja" or "en": which notes to show.
private var currentLanguageCode: String {
    Localization.language == .japanese ? "ja" : "en"
}
