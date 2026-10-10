import SwiftUI
import AbloxCore

// Settings → Updates → "Update history": every version so far and what each
// one changed, newest first (`UpdateHistory`, read from changelog.json beside
// update.json). Shared by Ablox and Ablox Studio (see `scripts/sync-core.sh`
// in the Studio repository).

/// The row in the Updates card that opens the history.
struct UpdateHistoryButton: View {
    @ObservedObject var updater: AppUpdater
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label(L("Update history"), systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(NeonButtonStyle(.secondary))
        .sheet(isPresented: $showing) {
            UpdateHistorySheet(updater: updater)
        }
    }
}

/// Every version, newest first, with this iPad's marked.
struct UpdateHistorySheet: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("What changed in each version, newest first."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                    if updater.historyLoading && updater.history == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L("Getting the update history…"))
                                .font(.caption)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                        }
                    }
                    if updater.historyFailed {
                        HStack(spacing: 10) {
                            Label(L("Could not read the whole history. Check the internet and try again."), systemImage: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(Ablox.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(L("Try again")) { Task { await updater.loadHistory() } }
                                .buttonStyle(NeonButtonStyle(.secondary))
                        }
                    }
                    ForEach(releases) { release in
                        UpdateHistoryRow(release: release,
                                         standing: UpdateHistory.standing(of: release, installed: updater.release.version,
                                                                          build: updater.release.build))
                    }
                }
                .padding(20)
            }
            .navigationTitle(L("Update history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .task { await updater.loadHistory() }
        .presentationDetents([.large])
    }

    /// The history, with the newest manifest added in case the history file
    /// is behind or could not be read.
    private var releases: [UpdateHistory.Release] {
        let base = updater.history ?? UpdateHistory(app: updater.release.app, releases: [])
        return base.including(updater.latest).releases
    }
}

/// One version: its number, date, and what it changed.
struct UpdateHistoryRow: View {
    let release: UpdateHistory.Release
    let standing: UpdateHistory.Standing

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(release.version.description)
                        .font(.headline)
                    Text("(\(release.build))")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkFaint)
                    switch standing {
                    case .installed: Badge(L("This iPad"), color: Ablox.Palette.success, systemImage: "checkmark")
                    case .newer: Badge(L("Update available"))
                    case .older: EmptyView()
                    }
                    Spacer()
                    Text(release.date)
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                }
                ForEach(Array(release.notes(for: historyLanguageCode).enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "sparkle")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// "ja" or "en": which notes to show.
private var historyLanguageCode: String {
    Localization.language == .japanese ? "ja" : "en"
}
