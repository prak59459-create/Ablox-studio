import SwiftUI

/// The Studio's landing screen: pick a project, make one, or join someone
/// else's editing session.
struct ProjectBrowserView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var settings: StudioSettings

    @State private var openSession: StudioSession?
    @State private var isCreating = false
    @State private var newName = ""
    @State private var selectedTemplate: ProjectStore.Template = .starter
    @State private var pendingDeletion: ProjectStore.Entry?
    @State private var showingVersions: ProjectStore.Entry?
    @State private var showingDeleted = false

    @StateObject private var browser = BrowserModel()
    @State private var joiningPeer: DiscoveredPeer?
    @State private var joinCode = ""
    @State private var isAsking = false
    @State private var isBrowsingGames = false
    /// A published game downloaded in the sheet, opened once the sheet has
    /// gone — presenting the editor over a sheet still on its way out is
    /// refused.
    @State private var downloadedGame: WorldDocument?

    var body: some View {
        ZStack {
            DynamicBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    projectsSection
                    collaborateSection
                }
                .padding(32)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Ablox.Palette.accent)
        .fullScreenCover(item: $openSession) { session in
            StudioView(session: session) {
                session.save()
                session.stopSharing()
                openSession = nil
                store.reload()
            }
        }
        .sheet(isPresented: $isCreating) { createSheet }
        .sheet(item: $showingVersions) { entry in
            WorldVersionsSheet(entry: entry).environmentObject(store)
        }
        .sheet(isPresented: $showingDeleted) {
            RecentlyDeletedSheet().environmentObject(store)
        }
        .sheet(isPresented: $isAsking) {
            MapAISheet { world in
                // Straight into the editor: the point of generating a level is
                // to look at it, and a world that lands silently in a list is
                // a world nobody opens.
                openSession = StudioSession(
                    world: world,
                    store: store,
                    localPeerID: settings.peerID,
                    profile: settings.profile
                )
            }
        }
        .sheet(isPresented: $isBrowsingGames, onDismiss: openDownloadedGame) {
            GameListSheet(source: settings.catalogueSource) { world in
                downloadedGame = world
            }
        }
        .sheet(item: $joiningPeer) { peer in
            joinSheet(peer)
        }
        .alert(L("Delete this project?"), isPresented: .constant(pendingDeletion != nil)) {
            Button(L("Cancel"), role: .cancel) { pendingDeletion = nil }
            Button(L("Delete"), role: .destructive) {
                if let pendingDeletion { store.delete(pendingDeletion) }
                pendingDeletion = nil
            }
        } message: {
            Text(L("“{}” moves to Recently Deleted, where it can be put back for 30 days.", pendingDeletion?.name ?? ""))
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            // The same drawn cube the client uses, so both apps present one
            // brand rather than two near-misses.
            AbloxLockup(subtitle: L("STUDIO · Build 3D worlds on iPad"), markSize: 54)

            Spacer()

            languageMenu

            if !store.deleted.isEmpty {
                Button { showingDeleted = true } label: {
                    Label(L("Recently deleted"), systemImage: "trash")
                }
                .buttonStyle(NeonButtonStyle(.secondary))
            }

            Button {
                isBrowsingGames = true
            } label: {
                Label(L("Open a published game"), systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(NeonButtonStyle(.secondary))

            Button {
                isAsking = true
            } label: {
                Label(L("Make with AI"), systemImage: "wand.and.stars")
            }
            .buttonStyle(NeonButtonStyle(.secondary))

            Button {
                newName = store.uniqueName(basedOn: "My World")
                selectedTemplate = .starter
                isCreating = true
            } label: {
                Label(L("New project"), systemImage: "plus")
            }
            .buttonStyle(NeonButtonStyle(.primary))
        }
    }

    /// The language switch, on the landing screen rather than behind a
    /// settings screen Studio does not have. Each row is written in the
    /// language it selects, so someone who cannot read the current interface
    /// can still recognise theirs.
    private var languageMenu: some View {
        Menu {
            Picker(L("Language"), selection: $settings.language) {
                ForEach(LanguagePreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
        } label: {
            Label(L("Language"), systemImage: "globe")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: Ablox.Metrics.minimumTapTarget, height: Ablox.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .foregroundStyle(Ablox.Palette.inkMuted)
        .accessibilityLabel(L("Language"))
    }

    // MARK: Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionHeader(L("Your projects"), systemImage: "square.stack.3d.up.fill")

            if let error = store.lastError {
                GlassCard {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Ablox.Palette.warning)
                }
            }

            if store.entries.isEmpty {
                GlassCard {
                    EmptyStateView(
                        title: "Nothing built yet",
                        message: "Start from the obstacle-course template to see how spawn points, coins and goals fit together — or start blank and make it up.",
                        systemImage: "cube.transparent"
                    )
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 15)], spacing: 15) {
                    ForEach(store.entries) { entry in
                        projectCard(entry)
                    }
                }
            }
        }
    }

    private func projectCard(_ entry: ProjectStore.Entry) -> some View {
        Button {
            open(entry)
        } label: {
            GlassCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        AbloxMark()
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .frame(width: 42, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                        Spacer()
                        Menu {
                            Button { store.duplicate(entry) } label: {
                                Label(L("Duplicate"), systemImage: "doc.on.doc")
                            }
                            Button { showingVersions = entry } label: {
                                Label(L("Earlier versions"), systemImage: "clock.arrow.circlepath")
                            }
                            Divider()
                            Button(role: .destructive) { pendingDeletion = entry } label: {
                                Label(L("Delete"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(Ablox.Palette.inkMuted)
                                .frame(width: 44, height: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.headline)
                            .foregroundStyle(Ablox.Palette.ink)
                            .lineLimit(1)
                        Text(entry.subtitle)
                            .font(.caption)
                            .foregroundStyle(Ablox.Palette.inkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Collaboration

    private var collaborateSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionHeader(L("Build together"), systemImage: "person.2.fill") {
                if browser.peers.isEmpty && browser.unavailableReason == nil {
                    ProgressView().controlSize(.small).tint(Ablox.Palette.accent)
                }
            }

            if let reason = browser.unavailableReason {
                GlassCard {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Ablox.Palette.warning)
                }
            } else if browser.studioPeers.isEmpty {
                GlassCard {
                    EmptyStateView(
                        title: "No shared projects nearby",
                        message: "When someone taps Share inside Ablox Studio, their project appears here and you can edit it together.",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
            } else {
                VStack(spacing: 11) {
                    ForEach(browser.studioPeers) { peer in
                        GlassCard(padding: 15) {
                            HStack(spacing: 13) {
                                Image(systemName: "hammer.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Ablox.Palette.warning)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(peer.worldName)
                                        .font(.headline)
                                        .foregroundStyle(Ablox.Palette.ink)
                                    Text(L("{} · {}", peer.hostName, peer.subtitle))
                                        .font(.caption)
                                        .foregroundStyle(Ablox.Palette.inkMuted)
                                }
                                Spacer()
                                if peer.isCompatible {
                                    Button(L("Join")) {
                                        joinCode = ""
                                        joiningPeer = peer
                                    }
                                    .buttonStyle(NeonButtonStyle(.primary))
                                } else {
                                    Badge(L("Update needed"), color: Ablox.Palette.warning)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ entry: ProjectStore.Entry) {
        guard let world = store.load(entry) else { return }
        openSession = StudioSession(
            world: world,
            store: store,
            localPeerID: settings.peerID,
            profile: settings.profile
        )
    }

    /// A published game becomes a project of its own: saved under a name
    /// not already taken, then opened. `GameLibrary` has already given it a
    /// new id, so it cannot replace anything on this iPad.
    private func openDownloadedGame() {
        guard var world = downloadedGame else { return }
        downloadedGame = nil
        world.name = store.uniqueName(basedOn: world.name)
        guard store.save(world) else { return }
        openSession = StudioSession(
            world: world,
            store: store,
            localPeerID: settings.peerID,
            profile: settings.profile
        )
    }

    // MARK: Sheets

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L("New project")).font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 7) {
                Text(L("Name")).font(.caption.weight(.semibold)).foregroundStyle(Ablox.Palette.inkMuted)
                TextField(L("My World"), text: $newName)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(L("Start from")).font(.caption.weight(.semibold)).foregroundStyle(Ablox.Palette.inkMuted)
                ForEach(ProjectStore.Template.allCases) { template in
                    Button { selectedTemplate = template } label: {
                        HStack(spacing: 13) {
                            Image(systemName: template.symbolName)
                                .font(.title3)
                                .frame(width: 30)
                                .foregroundStyle(selectedTemplate == template ? Ablox.Palette.accent : Ablox.Palette.inkMuted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.displayName).font(.headline).foregroundStyle(Ablox.Palette.ink)
                                Text(template.detail)
                                    .font(.caption)
                                    .foregroundStyle(Ablox.Palette.inkMuted)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: selectedTemplate == template ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedTemplate == template ? Ablox.Palette.accent : Ablox.Palette.inkFaint)
                        }
                        .padding(13)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(selectedTemplate == template ? Ablox.Palette.accent.opacity(0.55) : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 11) {
                Button(L("Cancel")) { isCreating = false }
                    .buttonStyle(NeonButtonStyle(.secondary, fullWidth: true))
                Button(L("Create")) {
                    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let world = store.createWorld(
                        named: trimmed.isEmpty ? "My World" : trimmed,
                        template: selectedTemplate,
                        author: settings.profile.displayName
                    )
                    isCreating = false
                    openSession = StudioSession(
                        world: world,
                        store: store,
                        localPeerID: settings.peerID,
                        profile: settings.profile
                    )
                }
                .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
            }
        }
        .padding(26)
        .frame(maxWidth: 520)
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func joinSheet(_ peer: DiscoveredPeer) -> some View {
        ScrollView {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(peer.worldName).font(.title2.weight(.bold))
                Text(L("Shared by {}", peer.hostName))
                    .font(.subheadline)
                    .foregroundStyle(Ablox.Palette.inkMuted)
            }
            .padding(.top, 26)

            VStack(spacing: 8) {
                Text(L("Room code"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ablox.Palette.inkMuted)
                // A hardware keyboard types straight into the field; the pad
                // below is for every iPad where the on-screen keyboard does not
                // appear — see `CodePad`.
                TextField("ABC DEF", text: Binding(
                    get: { RoomCode.formatted(joinCode) },
                    set: { joinCode = RoomCode.normalize($0) }
                ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.vertical, 12)
                    .frame(maxWidth: 250)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            CodePad(code: $joinCode)

            Button(L("Join and edit together")) {
                // A joined session starts from a blank world; the host's
                // snapshot replaces it as soon as it arrives.
                let session = StudioSession(
                    world: .blank(named: peer.worldName),
                    store: store,
                    localPeerID: settings.peerID,
                    profile: settings.profile
                )
                session.join(peer, code: joinCode)
                joiningPeer = nil
                openSession = session
            }
            .buttonStyle(NeonButtonStyle(.primary, fullWidth: true))
            .disabled(!RoomCode.isPlausible(joinCode))
            .opacity(RoomCode.isPlausible(joinCode) ? 1 : 0.5)
            .padding(.horizontal, 30)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
        }
        // Tall enough for the code pad. The old fixed 330 pt left no room for
        // anything but the field, which was no use on an iPad that never
        // shows its keyboard.
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }
}

// MARK: - Discovery model

/// Thin observable wrapper around `AbloxBrowser`, filtered to Studio sessions.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var unavailableReason: String?

    /// Studio only lists other Studio sessions — joining a running *game*
    /// from the editor would put you in a world you cannot edit.
    var studioPeers: [DiscoveredPeer] {
        peers.filter(\.isStudioSession)
    }

    private let browser = AbloxBrowser()

    init() {
        browser.onPeersChange = { [weak self] peers in
            Task { @MainActor in self?.peers = peers }
        }
        browser.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .browsing, .stopped: self?.unavailableReason = nil
                case let .unavailable(reason): self?.unavailableReason = reason
                }
            }
        }
    }

    func start() { browser.start() }
    func stop() { browser.stop() }
}
