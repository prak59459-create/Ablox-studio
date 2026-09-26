import SwiftUI

// Going back: a world's earlier versions, and worlds deleted in the last
// thirty days. Shared by Ablox and Ablox Studio (see `scripts/sync-core.sh`
// in the Studio repository), because a world lost in one is lost in both.

/// The kept versions of one world, newest first, each one tap from coming back.
public struct WorldVersionsSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    private let entry: ProjectStore.Entry
    private let onRestore: (WorldDocument) -> Void
    @State private var restoring: ProjectStore.Version?

    public init(entry: ProjectStore.Entry, onRestore: @escaping (WorldDocument) -> Void = { _ in }) {
        self.entry = entry
        self.onRestore = onRestore
    }

    public var body: some View {
        let versions = store.versions(of: entry)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("A version is kept every few minutes while you build. Going back keeps the current one as a version too, so you can change your mind."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if versions.isEmpty {
                        GlassCard {
                            EmptyStateView(title: L("No earlier versions yet"),
                                           message: L("They appear once the world has been saved a few times."),
                                           systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(versions) { version in
                        GlassCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(Ablox.Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(version.savedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Ablox.Palette.ink)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(version.byteCount), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(Ablox.Palette.inkMuted)
                                }
                                Spacer()
                                Button(L("Go back to this")) { restoring = version }
                                    .buttonStyle(NeonButtonStyle(.secondary))
                            }
                        }
                    }
                }
                .padding(Ablox.Metrics.gutter)
            }
            .navigationTitle(L("Earlier versions of “{}”", entry.name))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
            .alert(L("Go back to this version?"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
                Button(L("Cancel"), role: .cancel) { restoring = nil }
                Button(L("Go back")) {
                    if let version = restoring, let world = store.restore(version, of: entry) {
                        onRestore(world)
                        dismiss()
                    }
                    restoring = nil
                }
            } message: {
                Text(L("The world as it is now is kept, so this can be undone."))
            }
        }
    }
}

/// Worlds deleted in the last thirty days.
public struct RecentlyDeletedSheet: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEmpty = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Deleted worlds stay here for 30 days, then go for good."))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)

                    if store.deleted.isEmpty {
                        GlassCard {
                            EmptyStateView(title: L("Nothing deleted"), message: L("Worlds you delete wait here for 30 days."),
                                           systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(store.deleted) { item in
                        GlassCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "cube.transparent")
                                    .foregroundStyle(Ablox.Palette.inkMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Ablox.Palette.ink)
                                    Text(L("{} days left", item.daysLeft))
                                        .font(.caption)
                                        .foregroundStyle(Ablox.Palette.inkMuted)
                                }
                                Spacer()
                                Button(L("Put back")) { store.restore(item) }
                                    .buttonStyle(NeonButtonStyle(.primary))
                                Menu {
                                    Button(role: .destructive) { store.deleteForever(item) } label: {
                                        Label(L("Delete now"), systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(Ablox.Palette.inkMuted)
                                        .frame(width: Ablox.Metrics.minimumTapTarget, height: Ablox.Metrics.minimumTapTarget)
                                }
                            }
                        }
                    }
                }
                .padding(Ablox.Metrics.gutter)
            }
            .navigationTitle(L("Recently deleted"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !store.deleted.isEmpty {
                        Button(L("Empty"), role: .destructive) { confirmingEmpty = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
            .alert(L("Delete these worlds for good?"), isPresented: $confirmingEmpty) {
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Delete"), role: .destructive) { store.emptyRecentlyDeleted() }
            } message: {
                Text(L("This cannot be undone."))
            }
        }
    }
}
