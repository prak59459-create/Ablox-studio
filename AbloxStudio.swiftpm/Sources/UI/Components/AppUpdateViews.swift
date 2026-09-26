import SwiftUI

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

                Divider().background(Color.white.opacity(0.08))

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
                    Divider().background(Color.white.opacity(0.08))
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
