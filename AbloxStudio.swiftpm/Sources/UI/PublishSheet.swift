import SwiftUI
import UIKit

/// Preparing a world for the public game list.
///
/// The list is a GitHub repository, so publishing is a pull request. Studio
/// cannot open one — it has no account and no token, and giving a level editor
/// on a child's iPad the ability to push to a shared repository would be a
/// strange thing to build. What it can do is produce exactly the three files
/// that pull request needs, correctly named and already valid, so the only
/// remaining step is dropping them in.
///
/// The cover is drawn from the world rather than asked for. See `CoverArtwork`.
struct PublishSheet: View {
    let world: WorldDocument

    @EnvironmentObject private var settings: StudioSettings
    @Environment(\.dismiss) private var dismiss

    @State private var listing: GameListing
    @State private var tagText = ""
    @State private var exportedFolder: ExportedFolder?
    @State private var problem: String?
    @State private var copied = false

    init(world: WorldDocument) {
        self.world = world
        _listing = State(initialValue: GameListing.draft(for: world, author: ""))
    }

    private var artwork: CoverArtwork { CoverArtwork.make(from: world) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    coverPreview
                    details
                    whatHappensNext
                    actions

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.11))
            .navigationTitle(L("Publish this world"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ablox.Palette.accent)
        .onAppear {
            listing = GameListing.draft(for: world, author: settings.profile.displayName)
        }
        .sheet(item: $exportedFolder) { folder in
            ShareSheet(items: [folder.url])
        }
    }

    // MARK: Pieces

    private var coverPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("Cover image")).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
            CoverCanvas(artwork: artwork)
                .aspectRatio(CoverArtwork.size.width / CoverArtwork.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Ablox.Metrics.cardRadius, style: .continuous))
            Text(L("Drawn from the world, looking straight down. Start, goal, checkpoints and hazards are picked out."))
                .font(.caption2)
                .foregroundStyle(Ablox.Palette.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var details: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                field(L("Title"), text: Binding(
                    get: { listing.title },
                    set: { newValue in
                        listing.title = newValue
                        // The id follows the title until the files are written,
                        // so the folder and the listing always agree.
                        let id = GameListing.suggestedID(for: newValue)
                        listing.id = id
                        listing.world = "games/\(id)/world.ablox"
                        listing.cover = "games/\(id)/cover.png"
                    }
                ))
                field(L("Summary"), text: $listing.summary, axis: .vertical)
                field(L("Tags"), text: $tagText, hint: L("obstacle, race, easy"))

                HStack {
                    Text(L("Folder")).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
                    Spacer()
                    Text("games/\(listing.id)/")
                        .font(.caption.monospaced())
                        .foregroundStyle(Ablox.Palette.accent)
                }
                Text(L("The id is taken from the title and must be unique in the repository."))
                    .font(.caption2)
                    .foregroundStyle(Ablox.Palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whatHappensNext: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(L("What happens next"), systemImage: "arrow.up.doc")
                Text(L("Studio writes three files. Add them to the games repository with a pull request, and the game appears in Ablox for everyone."))
                    .font(.caption)
                    .foregroundStyle(Ablox.Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 9) {
            Button { export() } label: {
                Label(L("Export files"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))

            Button {
                UIPasteboard.general.string = finalListing.indexEntryJSON()
                copied = true
            } label: {
                Label(copied ? L("Copied") : L("Copy listing"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))

            if let url = settings.catalogueSource.webURL {
                Link(destination: url) {
                    Label(L("Open the games repository"), systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, hint: String = "", axis: Axis = .horizontal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Ablox.Palette.inkMuted)
            TextField(hint, text: text, axis: axis)
                .textFieldStyle(.plain)
                .lineLimit(axis == .vertical ? 3...5 : 1...1)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Exporting

    /// The listing with the tag field parsed, validated one last time.
    private var finalListing: GameListing {
        var listing = self.listing
        listing.tags = tagText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .prefix(GameCatalogue.Limits.maximumTags)
            .map(String.init)
        listing.blockCount = world.blocks.count
        listing.updatedAt = Date()
        return listing
    }

    private func export() {
        problem = nil
        let listing = finalListing

        // Refused here rather than in the pull request, where the person
        // finding out would be someone else.
        if let rejection = listing.rejection() {
            problem = rejection.message
            return
        }
        guard !listing.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            problem = L("Give the world a title before publishing it.")
            return
        }

        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ablox-publish/\(listing.id)", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            try world.encodedForFile().write(to: folder.appendingPathComponent("world.ablox"))
            try Data(listing.indexEntryJSON().utf8)
                .write(to: folder.appendingPathComponent("listing.json"))

            if let png = CoverRenderer.png(for: artwork) {
                try png.write(to: folder.appendingPathComponent("cover.png"))
            }

            exportedFolder = ExportedFolder(url: folder)
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Drawing the cover

/// The plan view, on screen and in the exported PNG, from one layout.
struct CoverCanvas: View {
    let artwork: CoverArtwork

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / CoverArtwork.size.width
            ZStack(alignment: .topLeading) {
                Color(artwork.background)
                ForEach(Array(artwork.shapes.enumerated()), id: \.offset) { _, shape in
                    RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                        .fill(Color(shape.color))
                        .overlay {
                            if shape.isLandmark {
                                RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                                    .strokeBorder(.white.opacity(0.9), lineWidth: Swift.max(1, 3 * scale))
                            }
                        }
                        .frame(width: shape.width * scale, height: shape.height * scale)
                        .offset(x: shape.x * scale, y: shape.y * scale)
                }
            }
        }
    }
}

/// Renders the same layout to a PNG for the exported file.
enum CoverRenderer {
    static func png(for artwork: CoverArtwork) -> Data? {
        let size = CGSize(width: CoverArtwork.size.width, height: CoverArtwork.size.height)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.pngData { context in
            artwork.background.uiColor.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            for shape in artwork.shapes {
                let rect = CGRect(x: shape.x, y: shape.y, width: shape.width, height: shape.height)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 3)
                shape.color.uiColor.setFill()
                path.fill()

                if shape.isLandmark {
                    UIColor.white.withAlphaComponent(0.9).setStroke()
                    path.lineWidth = 3
                    path.stroke()
                }
            }
        }
    }
}

// MARK: - Sharing

/// The system share sheet, so the exported folder can go to Files, AirDrop or
/// anywhere else the person already keeps things.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `sheet(item:)` needs an `Identifiable`, and a URL is not one.
///
/// Wrapped rather than extended: `extension URL: Identifiable` would be a
/// retroactive conformance on a Foundation type, which needs `@retroactive` on
/// a Swift 6 compiler and is a syntax error on an older one — and the compiler
/// inside Swift Playgrounds is not something this project can check.
struct ExportedFolder: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
