import Foundation
import Combine
import AbloxCore
import EditorCore

/// The observable wrapper the SwiftUI layer binds to.
///
/// All editing logic lives in `EditorDocument`, which is a portable value type
/// with no framework dependencies. This class exists only to publish changes
/// and to bridge to the network and the disk — so the testable part stays
/// testable, and this part stays thin enough to read in one sitting.
@MainActor
public final class StudioSession: ObservableObject, Identifiable {

    /// Identity for `fullScreenCover(item:)`, which needs to tell one opened
    /// project from another.
    public let id = UUID()

    public enum Mode: Equatable {
        case edit
        case play
    }

    @Published public private(set) var document: EditorDocument
    @Published public var mode: Mode = .edit
    @Published public private(set) var collaborators: [PlayerSnapshot] = []
    @Published public private(set) var statusMessage: String?

    /// Non-nil while hosting a co-editing session.
    @Published public private(set) var roomCode: String?
    @Published public private(set) var isHosting = false

    private var host: AbloxHost?
    private var client: AbloxClient?
    private let store: ProjectStore
    private let localPeerID: PeerID
    private let profile: AvatarProfile

    private var autosaveTask: Task<Void, Never>?

    public init(world: WorldDocument, store: ProjectStore, localPeerID: PeerID, profile: AvatarProfile) {
        self.document = EditorDocument(world: world)
        self.store = store
        self.localPeerID = localPeerID
        self.profile = profile
    }

    deinit {
        autosaveTask?.cancel()
    }

    // MARK: Editing

    /// Runs an edit and broadcasts whatever deltas it produced.
    ///
    /// Every mutation funnels through here, so there is exactly one place that
    /// remembers to publish — rather than each call site having to.
    public func edit(_ body: (inout EditorDocument) -> Void) {
        body(&document)
        publishPendingDeltas()
        scheduleAutosave()
    }

    private func publishPendingDeltas() {
        let deltas = document.drainDeltas()
        guard !deltas.isEmpty else { return }
        for delta in deltas {
            host?.publish(delta: delta)
            client?.publish(delta: delta)
        }
    }

    // MARK: Convenience wrappers

    public func addPart(_ kind: BlockData.PresetKind, at position: Vec3) {
        edit { $0.addPart(kind, at: position) }
    }

    public func deleteSelection() {
        edit { $0.deleteSelection() }
    }

    public func duplicateSelection() {
        edit { $0.duplicateSelection() }
    }

    public func undo() {
        edit { $0.undo() }
    }

    public func redo() {
        edit { $0.redo() }
    }

    public func select(_ id: UUID?, additive: Bool = false) {
        document.select(id, additive: additive)
    }

    public func setTool(_ tool: EditorDocument.Tool) {
        document.tool = tool
    }

    /// Snap settings are read straight off the document but written through
    /// here, because `document` is `private(set)` — every mutation belongs to
    /// this class so that nothing can change the world without the deltas
    /// being published.
    public var gridSize: Float {
        get { document.gridSize }
        set { document.gridSize = newValue }
    }

    public var angleSnap: Float {
        get { document.angleSnap }
        set { document.angleSnap = newValue }
    }

    // MARK: Saving

    public func save() {
        guard store.save(document.world) else {
            statusMessage = store.lastError
            return
        }
        document.markSaved()
        flash("Saved")
    }

    /// Debounced autosave. A drag produces an edit every frame; writing the
    /// world to disk each time would thrash flash storage for no benefit.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.document.hasUnsavedChanges else { return }
            _ = self.store.save(self.document.world)
            self.document.markSaved()
        }
    }

    private func flash(_ message: String) {
        statusMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            if self?.statusMessage == message { self?.statusMessage = nil }
        }
    }

    // MARK: Co-editing

    /// Opens this project to other iPads over the same TLS mesh the game uses.
    public func startHosting() {
        stopSharing()

        let code = RoomCode.generate()
        let configuration = AbloxHost.Configuration(
            worldName: document.world.name,
            hostName: profile.displayName.isEmpty ? "Ablox Studio" : "\(profile.displayName)'s Studio",
            capacity: 4,
            roomCode: code,
            isStudioSession: true
        )

        let host = AbloxHost(
            world: document.world,
            configuration: configuration,
            localPeerID: localPeerID,
            localProfile: profile
        )

        host.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .hosting:
                    self.isHosting = true
                    self.roomCode = code
                    self.flash("Sharing — room code \(RoomCode.formatted(code))")
                case let .failed(reason):
                    self.isHosting = false
                    self.roomCode = nil
                    self.statusMessage = reason
                case .idle, .starting:
                    break
                }
            }
        }

        host.onRosterChange = { [weak self] roster in
            Task { @MainActor in self?.collaborators = roster }
        }

        host.onRemoteDelta = { [weak self] delta in
            Task { @MainActor in self?.document.applyRemote(delta) }
        }

        self.host = host
        host.start()
    }

    /// Joins someone else's Studio session.
    public func join(_ peer: DiscoveredPeer, code: String) {
        stopSharing()

        let client = AbloxClient(localPeerID: localPeerID, profile: profile)

        client.onWorld = { [weak self] world in
            Task { @MainActor in
                guard let self else { return }
                // The host's world replaces ours wholesale — and the undo
                // history with it, since it described a document that is no
                // longer on screen.
                self.document = EditorDocument(world: world)
                self.flash("Joined \(world.name)")
            }
        }

        client.onDelta = { [weak self] delta in
            Task { @MainActor in self?.document.applyRemote(delta) }
        }

        client.onRoster = { [weak self] roster in
            Task { @MainActor in self?.collaborators = roster }
        }

        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard case let .disconnected(reason) = state else { return }
                self?.statusMessage = reason
                self?.collaborators = []
            }
        }

        self.client = client
        client.connect(to: peer, roomCode: code)
    }

    public func stopSharing() {
        host?.stop()
        host = nil
        client?.disconnect()
        client = nil
        isHosting = false
        roomCode = nil
        collaborators = []
    }

    // MARK: Play mode

    /// Switches between building and testing.
    ///
    /// Entering play mode saves first: a crash while testing must not lose the
    /// work, and the play simulation reads the saved world.
    public func toggleMode() {
        switch mode {
        case .edit:
            save()
            document.clearSelection()
            mode = .play
        case .play:
            mode = .edit
        }
    }

    // MARK: Validation

    public var issues: [WorldDocument.ValidationIssue] {
        document.issues
    }
}
