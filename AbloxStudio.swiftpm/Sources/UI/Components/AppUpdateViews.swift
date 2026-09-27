import SwiftUI
import UniformTypeIdentifiers
import AbloxCore

// What the player sees of `AppUpdater`: a banner in the menu when a new
// version is out or already downloaded, a card in Settings, the sheet that
// hands the new project to Swift Playgrounds, and what changed after it.
// Shared by Ablox and Ablox Studio (see `scripts/sync-core.sh` in the
// Studio repository), which update the same way.

/// A strip across the top of the menu: there is something newer.
public struct UpdateBanner: View {
    @ObservedObject private var updater: AppUpdater
    private let install: () -> Void
    @State private var hidden = false

    public init(updater: AppUpdater, install: @escaping () -> Void) {
        self.updater = updater
        self.install = install
    }

    public var body: some View {
        if !hidden, let latest = updater.latest, updater.shouldOffer || updater.phase == .ready {
            HStack(spacing: 12) {
                Image(systemName: updater.isRequired ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.app.fill")
                    .font(.title3)
                    .foregroundStyle(updater.isRequired ? Ablox.Palette.warning : Ablox.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("{} {} is out", updater.release.app, latest.version.description))
                        .font(.subheadline.weight(.bold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                action
                if !updater.isRequired {
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
                    .strokeBorder((updater.isRequired ? Ablox.Palette.warning : Ablox.Palette.accent).opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal, Ablox.Metrics.gutter)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var detail: String {
        switch updater.phase {
        case .downloading: return L("Downloading…")
        case .unpacking: return L("Getting it ready…")
        case .ready: return L("Downloaded and ready. Two taps and you have it.")
        case let .failed(message): return message
        default:
            return updater.isRequired
                ? L("Friends with the new version cannot play with this one until it updates.")
                : (updater.latest?.notes(for: currentLanguageCode).first ?? L("A newer version of this app is ready to download."))
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.phase {
        case .downloading, .unpacking, .checking:
            ProgressView().tint(Ablox.Palette.accent)
        case .ready:
            Button(L("Install"), action: install)
                .buttonStyle(NeonButtonStyle(.primary))
        default:
            Button(L("Download")) { Task { await updater.download() } }
                .buttonStyle(NeonButtonStyle(.primary))
        }
    }
}

/// Settings: which version this is, whether there is a newer one, and
/// whether to look and download by itself.
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

                HStack(spacing: 10) {
                    switch updater.phase {
                    case .ready:
                        Button(action: install) {
                            Label(L("Install"), systemImage: "square.and.arrow.down.on.square")
                        }
                        .buttonStyle(NeonButtonStyle(.primary))
                    case .available, .failed:
                        if updater.availability != .current {
                            Button { Task { await updater.download() } } label: {
                                Label(L("Download"), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(NeonButtonStyle(.primary))
                        }
                    default:
                        EmptyView()
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
                    label(L("Look for updates by itself"), L("When the app opens, and every few hours while it is open."))
                }
                .tint(Ablox.Palette.accent)
                Toggle(isOn: $updater.downloadsAutomatically) {
                    label(L("Download them by itself"), L("On Wi-Fi only, so it is ready when you are. Nothing is installed without you."))
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
            if case let .success(url) = result { linkProblem = updater.linkProject(at: url) }
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

/// The last step, which only a person can take: giving the new project to
/// Swift Playgrounds.
public struct UpdateInstallSheet: View {
    @ObservedObject private var updater: AppUpdater
    /// A backup of everything, made as the sheet opens.
    private let backup: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var choosingProject = false
    @State private var linkProblem: String?

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
                        Text(L("Downloaded and checked. Everything you have stays."))
                            .font(.subheadline)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                    }
                }

                inPlaceChoice

                Text(L("Or as a new project:"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ablox.Palette.inkMuted)
                step(1, L("Tap the button below and choose Swift Playgrounds. (Not in the list? Choose “Save to Files” and put it in the Playgrounds folder.)"))
                if let package = updater.stagedPackage {
                    ShareLink(item: package) {
                        Label(L("Send to Swift Playgrounds"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
                }
                step(2, L("In Swift Playgrounds, open the new {} and press ▶︎.", updater.release.app))
                step(3, L("That's it. Your worlds, coins and saved games carry over. When the new one runs, you can delete the old one."))

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

                Button(L("Later")) { dismiss() }
                    .buttonStyle(NeonButtonStyle(.secondary))
            }
            .padding(28)
        }
        .presentationDetents([.large])
        .fileImporter(isPresented: $choosingProject, allowedContentTypes: ProjectLinkRow.types) { result in
            if case let .success(url) = result { linkProblem = updater.linkProject(at: url) }
        }
    }

    /// The quick way: only the changed files, into the project already here.
    private var inPlaceChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            if updater.linkedProject != nil {
                Button { Task { await updater.installInPlace() } } label: {
                    Label(L("Put it straight into {} on this iPad", updater.linkedProject ?? updater.release.package), systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
                .disabled(updater.inPlace == .working)
                Text(L("Only the files that changed are written, so the next build is quick. Then go back to Swift Playgrounds and press ▶︎."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Quicker: choose the project already on this iPad, and only the files that changed are written into it."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProjectLinkRow(updater: updater, problem: $linkProblem) { choosingProject = true }
            InPlaceStatusLine(updater: updater)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
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
