import SwiftUI

/// Opening a published game from the game list as a new project.
///
/// The same list, repository and branch the Games tab in Ablox reads — the
/// setting is shared on the iPad — and the same `GameLibrary`, so everything
/// it checks about a download is checked here too. The world arrives with its
/// map, its rules and its `.absc` files, under a new id, so editing it never
/// touches anything already on this iPad.
struct GameListSheet: View {
    @EnvironmentObject private var settings: StudioSettings
    @Environment(\.dismiss) private var dismiss

    /// Called with the downloaded world, so the caller can save and open it.
    let onOpen: (WorldDocument) -> Void

    @StateObject private var library: GameLibrary
    @State private var opening: String?

    init(source: CatalogueSource, onOpen: @escaping (WorldDocument) -> Void) {
        self.onOpen = onOpen
        _library = StateObject(wrappedValue: GameLibrary(source: source))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceCard
                    statusLine

                    if library.listings.isEmpty, library.status != .refreshing {
                        GlassCard {
                            EmptyStateView(
                                title: L("No games here yet"),
                                message: L("Check the repository and the branch, then tap Reload."),
                                systemImage: "square.stack.3d.up.slash"
                            )
                        }
                    }

                    ForEach(library.listings) { listing in
                        row(listing)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle(L("Open a published game"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ablox.Palette.accent)
        .task { await library.refresh() }
    }

    // MARK: Pieces

    private var sourceCard: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Which GitHub repository the Games tab reads."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)

                HStack(spacing: 8) {
                    field("owner/repo", text: $settings.catalogueRepository)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                    field("main", text: $settings.catalogueBranch)
                        .frame(maxWidth: 160)
                    Button {
                        library.source = settings.catalogueSource
                        Task { await library.refresh() }
                    } label: {
                        Label(L("Reload"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(NeonButtonStyle(.secondary))
                    .disabled(library.status == .refreshing)
                }

                Text(verbatim: "\(library.source.repository)@\(library.source.reference)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Ablox.Palette.inkFaint)
                Text(L("Ablox uses the same list and branch on this iPad."))
                    .font(.caption2)
                    .foregroundStyle(Ablox.Palette.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch library.status {
        case .idle:
            EmptyView()
        case .refreshing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Loading the game list…"))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
        case let .offline(message), let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Ablox.Palette.warning)
        }
    }

    private func row(_ listing: GameListing) -> some View {
        GlassCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: listing.title)
                        .font(.headline)
                        .foregroundStyle(Ablox.Palette.ink)
                    Text(L("by {}", listing.author))
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                    Text(verbatim: listing.summary)
                        .font(.caption)
                        .foregroundStyle(Ablox.Palette.inkMuted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let scripts = listing.scripts, !scripts.isEmpty {
                        Label(L("{} script files", scripts.count), systemImage: "curlybraces")
                            .font(.caption2)
                            .foregroundStyle(Ablox.Palette.accent)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    open(listing)
                } label: {
                    if opening == listing.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(L("Open in Studio"), systemImage: "hammer.fill")
                    }
                }
                .buttonStyle(NeonButtonStyle(.primary))
                .disabled(opening != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.callout.monospaced())
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Opening

    private func open(_ listing: GameListing) {
        opening = listing.id
        Task { @MainActor in
            defer { opening = nil }
            guard let world = await library.download(listing) else { return }
            onOpen(world)
            dismiss()
        }
    }
}
