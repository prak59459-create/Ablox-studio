import Foundation
import Combine
import UIKit

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

    // MARK: Building together

    /// Lines said while co-editing, newest last.
    @Published public private(set) var chat: [StudioChatLine] = []
    /// Where each co-editor is looking or working.
    @Published public private(set) var presence: [PeerID: Vec3] = [:]
    /// Places pointed at in the chat, for a few seconds each.
    @Published public private(set) var pins: [StudioPin] = []
    private var lastFocusSent = Date.distantPast
    /// What was last copied, for iPads whose pasteboard is shared with nothing.
    private var lastClipboard: PartClipboard?

    public init(world: WorldDocument, store: ProjectStore, localPeerID: PeerID, profile: AvatarProfile) {
        self.document = EditorDocument(world: world)
        self.store = store
        self.localPeerID = localPeerID
        self.profile = profile
        // The layers hidden or locked last time, per world.
        let key = "ablox.studio.layers." + world.id.uuidString
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] {
            document.hiddenLayers = Set(saved["hidden"] ?? [])
            document.lockedLayers = Set(saved["locked"] ?? [])
        }
    }

    public var localID: PeerID { localPeerID }

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
        flash(L("Saved"))
    }

    /// Settings → Autosave: seconds after the last change (0: only by hand).
    nonisolated public static let autosaveKey = "ablox.studio.autosaveSeconds"

    /// Debounced autosave. A drag produces an edit every frame; writing the
    /// world to disk each time would thrash flash storage for no benefit.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let stored = UserDefaults.standard.object(forKey: Self.autosaveKey) as? Double ?? 3
        guard stored > 0 else { return }
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(stored * 1_000_000_000))
            guard !Task.isCancelled, let self, self.document.hasUnsavedChanges else { return }
            _ = self.store.save(self.document.world)
            self.document.markSaved()
        }
    }

    // MARK: Copy, paste and the library

    public func copySelection() {
        guard let clip = document.copySelection(), let data = clip.encoded else { return }
        lastClipboard = clip
        UIPasteboard.general.setData(data, forPasteboardType: PartClipboard.pasteboardType)
        flash(L("Copied {} parts", clip.blocks.count))
    }

    /// Parts copied here or in another world, at `point`.
    public func paste(at point: Vec3) {
        let fromPasteboard = UIPasteboard.general.data(forPasteboardType: PartClipboard.pasteboardType).flatMap(PartClipboard.init(data:))
        guard let clip = fromPasteboard ?? lastClipboard else {
            flash(L("Nothing copied yet"))
            return
        }
        edit { $0.paste(clip, at: point) }
    }

    public func insert(_ prefab: Prefab, at point: Vec3) {
        edit { $0.paste(PartClipboard(blocks: prefab.blocks), at: point) }
    }

    /// Hides or locks a layer in this editor (games show every layer).
    public func setLayer(_ name: String, hidden: Bool? = nil, locked: Bool? = nil) {
        if let hidden { if hidden { document.hiddenLayers.insert(name) } else { document.hiddenLayers.remove(name) } }
        if let locked { if locked { document.lockedLayers.insert(name) } else { document.lockedLayers.remove(name) } }
        document.selection = document.selection.filter { id in document.world.block(id: id).map(document.isPickable) ?? false }
        UserDefaults.standard.set(["hidden": Array(document.hiddenLayers), "locked": Array(document.lockedLayers)],
                                  forKey: "ablox.studio.layers." + document.world.id.uuidString)
    }

    /// The paint tool's colour, remembered with the recent ones.
    public func setPaintColor(_ color: ColorRGBA) {
        document.paintColor = color
        var recent = document.recentColors.filter { $0 != color }
        recent.insert(color, at: 0)
        document.recentColors = Array(recent.prefix(10))
    }

    public func setTerrain(_ action: TerrainAction? = nil, brush: Int? = nil) {
        if let action { document.terrainAction = action }
        if let brush { document.terrainBrush = max(1, min(4, brush)) }
    }

    // MARK: Building together: chat, pins and who is where

    public func sendChat(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !trimmed.isEmpty else { return }
        if let host { host.sendChat(trimmed) } else if let client { client.sendChat(trimmed) } else {
            chat.append(StudioChatLine(name: profile.displayName, text: trimmed, isMine: true))
        }
    }

    /// Points everyone at a place: a pin that shows for a few seconds.
    public func sendPin(at point: Vec3) {
        sendChat(StudioPin.message(for: point))
    }

    private func received(_ payload: ChatPayload, from sender: PeerID) {
        let isMine = sender == localPeerID
        if let point = StudioPin.point(in: payload.text) {
            let pin = StudioPin(point: point, name: isMine ? L("You") : payload.senderName)
            pins.append(pin)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.pins.removeAll { $0.id == pin.id }
            }
        }
        chat.append(StudioChatLine(name: payload.senderName, text: payload.text, isMine: isMine))
        if chat.count > 100 { chat.removeFirst(chat.count - 100) }
    }

    /// Where this builder is working, for co-editors' screens. At most twice
    /// a second.
    public func noteFocus(_ point: Vec3) {
        guard host != nil || client != nil, Date().timeIntervalSince(lastFocusSent) > 0.5 else { return }
        lastFocusSent = Date()
        let target = document.selectionBounds?.center ?? point
        let snapshot = PlayerSnapshot(peerID: localPeerID, profile: profile, position: target)
        host?.publishLocalTransform(snapshot)
        client?.publishLocalTransform(snapshot)
    }

    private func moved(_ payload: PlayerTransformPayload) {
        guard payload.peerID != localPeerID else { return }
        presence[payload.peerID] = payload.position
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
                    self.flash(L("Sharing — room code {}", RoomCode.formatted(code)))
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

        host.onChat = { [weak self] sender, payload in
            Task { @MainActor in self?.received(payload, from: sender) }
        }

        host.onRemoteTransform = { [weak self] payload in
            Task { @MainActor in self?.moved(payload) }
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
                self.flash(L("Joined {}", world.name))
            }
        }

        client.onDelta = { [weak self] delta in
            Task { @MainActor in self?.document.applyRemote(delta) }
        }

        client.onRoster = { [weak self] roster in
            Task { @MainActor in self?.collaborators = roster }
        }

        client.onChat = { [weak self] sender, payload in
            Task { @MainActor in self?.received(payload, from: sender) }
        }

        client.onTransform = { [weak self] payload in
            Task { @MainActor in self?.moved(payload) }
        }

        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard case let .disconnected(reason) = state else { return }
                // `reason` is a `DisconnectReason`, not a string. It was a
                // string until reconnection needed to tell a transient network
                // fault apart from a wrong room code, and this is the only
                // place outside the mirrored layers that reads it — so it was
                // the only one the change missed.
                self?.statusMessage = reason.message
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
        presence = [:]
        pins = []
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

/// A line said while building together.
public struct StudioChatLine: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var name: String
    public var text: String
    public var isMine: Bool
}

/// A place someone pointed at, sent as a chat line: "📍 x, y, z".
public struct StudioPin: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var point: Vec3
    public var name: String

    static let prefix = "📍"

    static func message(for point: Vec3) -> String {
        prefix + " " + [point.x, point.y, point.z].map { String(format: "%.1f", $0) }.joined(separator: ", ")
    }

    static func point(in text: String) -> Vec3? {
        guard text.hasPrefix(prefix) else { return nil }
        let numbers = text.dropFirst(prefix.count).split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { return nil }
        return Vec3(numbers[0], numbers[1], numbers[2])
    }
}
