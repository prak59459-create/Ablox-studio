import Foundation
import Combine
import Network

/// The single object the UI binds to for anything network-shaped.
///
/// Hides the host/client split behind one surface: views ask "what is the
/// world, who is here, what is my ping" without caring which side of the
/// connection they are on. Everything published here is touched only on the
/// main actor; the host and client deliver their callbacks on their own
/// queues, and this class is the one place that hops.
@MainActor
public final class SessionCoordinator: ObservableObject {

    public enum Role: Equatable {
        case offline
        case hosting
        case joined
    }

    public enum Status: Equatable {
        case idle
        case searching
        case connecting
        case active
        case error(String)

        public var isBusy: Bool { self == .connecting || self == .searching }
    }

    // MARK: Published state

    @Published public private(set) var role: Role = .offline
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var world: WorldDocument = .blank()
    @Published public private(set) var roster: [PlayerSnapshot] = []
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var chatLog: [ChatEntry] = []
    @Published public private(set) var announcement: Announcement?
    @Published public private(set) var pingMilliseconds: Double?
    @Published public private(set) var roomCode: String = ""
    @Published public private(set) var browserUnavailableReason: String?

    /// Effects the local renderer still has to apply (tints, moves, sounds).
    /// The viewport drains this each frame.
    @Published public private(set) var pendingEffects: [EventAction] = []

    public struct ChatEntry: Identifiable, Hashable {
        public let id = UUID()
        public let senderName: String
        public let text: String
        public let timestamp = Date()
    }

    public struct Announcement: Equatable {
        public let message: String
        public let expiresAt: Date
    }

    // MARK: Identity

    public let localPeerID: PeerID
    @Published public var profile: AvatarProfile {
        didSet {
            host?.updateLocalProfile(profile)
            client?.updateProfile(profile)
        }
    }

    // MARK: Internals

    private var host: AbloxHost?
    private var client: AbloxClient?
    private let browser = AbloxBrowser()
    private var announcementTask: Task<Void, Never>?

    public init(localPeerID: PeerID = PeerID(), profile: AvatarProfile = .default) {
        self.localPeerID = localPeerID
        self.profile = profile
        configureBrowser()
    }

    // MARK: Discovery

    private func configureBrowser() {
        browser.onPeersChange = { [weak self] peers in
            Task { @MainActor in self?.discoveredPeers = peers }
        }
        browser.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .browsing:
                    self.browserUnavailableReason = nil
                    if self.status == .idle { self.status = .searching }
                case let .unavailable(reason):
                    self.browserUnavailableReason = reason
                case .stopped:
                    if self.status == .searching { self.status = .idle }
                }
            }
        }
    }

    public func startBrowsing() {
        status = .searching
        browser.start()
    }

    public func stopBrowsing() {
        browser.stop()
    }

    // MARK: Hosting

    public func startHosting(world: WorldDocument, isStudioSession: Bool = false, capacity: Int = AbloxProtocol.defaultCapacity) {
        leave()

        self.world = world
        let code = RoomCode.generate()
        roomCode = code

        let configuration = AbloxHost.Configuration(
            worldName: world.name,
            hostName: profile.displayName.isEmpty ? "Ablox" : "\(profile.displayName)'s iPad",
            capacity: capacity,
            roomCode: code,
            isStudioSession: isStudioSession
        )

        let host = AbloxHost(world: world, configuration: configuration, localPeerID: localPeerID, localProfile: profile)

        host.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .hosting:
                    self.status = .active
                    self.role = .hosting
                case let .failed(reason):
                    self.status = .error(reason)
                    self.role = .offline
                case .starting:
                    self.status = .connecting
                case .idle:
                    if self.role == .hosting { self.role = .offline }
                }
            }
        }

        host.onRosterChange = { [weak self] roster in
            Task { @MainActor in self?.roster = roster }
        }

        host.onChat = { [weak self] payload in
            Task { @MainActor in self?.appendChat(payload) }
        }

        host.onLocalEffects = { [weak self] effects in
            Task { @MainActor in self?.apply(effects: effects.map(\.action)) }
        }

        host.onRemoteDelta = { [weak self] delta in
            Task { @MainActor in
                guard let self else { return }
                var world = self.world
                delta.apply(to: &world)
                self.world = world
            }
        }

        self.host = host
        host.start()
        host.startRound()
    }

    // MARK: Joining

    public func join(_ peer: DiscoveredPeer, roomCode code: String) {
        guard peer.isCompatible else {
            status = .error("That iPad is running a different version of Ablox.")
            return
        }
        guard !peer.isFull else {
            status = .error("That world is full.")
            return
        }

        leave()
        roomCode = RoomCode.normalize(code)
        status = .connecting

        let client = AbloxClient(localPeerID: localPeerID, profile: profile)

        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .playing:
                    self.status = .active
                    self.role = .joined
                case let .disconnected(reason):
                    self.status = .error(reason)
                    self.role = .offline
                case .connecting, .handshaking:
                    self.status = .connecting
                case .idle:
                    break
                }
            }
        }

        client.onWorld = { [weak self] world in
            Task { @MainActor in self?.world = world }
        }

        client.onDelta = { [weak self] delta in
            Task { @MainActor in
                guard let self else { return }
                var world = self.world
                delta.apply(to: &world)
                self.world = world
            }
        }

        client.onRoster = { [weak self] roster in
            Task { @MainActor in self?.roster = roster }
        }

        client.onTransform = { [weak self] payload in
            Task { @MainActor in self?.applyRemoteTransform(payload) }
        }

        client.onEffects = { [weak self] payload in
            Task { @MainActor in self?.apply(effects: payload.actions) }
        }

        client.onChat = { [weak self] payload in
            Task { @MainActor in self?.appendChat(payload) }
        }

        self.client = client
        client.connect(to: peer, roomCode: roomCode)
    }

    public func leave() {
        host?.stop()
        host = nil
        client?.disconnect()
        client = nil
        role = .offline
        status = .idle
        roster = []
        pingMilliseconds = nil
        pendingEffects = []
        announcementTask?.cancel()
        announcement = nil
    }

    // MARK: Gameplay bridge

    /// Publishes the local avatar. Called by the render loop at the protocol's
    /// tick rate, not every frame.
    public func publishLocalTransform(_ snapshot: PlayerSnapshot) {
        switch role {
        case .hosting: host?.publishLocalTransform(snapshot)
        case .joined: client?.publishLocalTransform(snapshot)
        case .offline: break
        }
        if role == .joined { pingMilliseconds = client?.pingMilliseconds }
    }

    /// Reports that the local player touched or tapped a block. The host
    /// decides what that means.
    public func report(blockID: UUID, cause: EventTriggerPayload.Cause) {
        switch role {
        case .hosting:
            let observation: EventMachine.Observation
            switch cause {
            case .touched: observation = .touched(peer: localPeerID, blockID: blockID)
            case .tapped: observation = .tapped(peer: localPeerID, blockID: blockID)
            case .proximityEntered: observation = .proximityEntered(peer: localPeerID, blockID: blockID)
            }
            host?.reportLocalObservation(observation)
        case .joined:
            client?.report(blockID: blockID, cause: cause)
        case .offline:
            // Solo play still runs rules, through a host with no listener
            // — see `startSoloSession`.
            break
        }
    }

    public func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch role {
        case .hosting: host?.sendChat(trimmed)
        case .joined: client?.sendChat(trimmed)
        case .offline: appendChat(ChatPayload(senderName: profile.displayName, text: trimmed))
        }
    }

    public func publish(delta: WorldDelta) {
        delta.apply(to: &world)
        switch role {
        case .hosting: host?.publish(delta: delta)
        case .joined: client?.publish(delta: delta)
        case .offline: break
        }
    }

    /// Replaces the world locally and, when hosting, pushes it to everyone.
    public func setWorld(_ newWorld: WorldDocument) {
        world = newWorld
    }

    // MARK: Effects

    private func apply(effects: [EventAction]) {
        for action in effects {
            switch action {
            case let .announce(message, duration):
                show(announcement: message, for: duration)
            case let .setVisible(blockID, visible):
                world.mutate(id: blockID) { $0.isVisible = visible }
            case let .setCollision(blockID, enabled):
                world.mutate(id: blockID) { $0.hasCollision = enabled }
            case let .endRound(message):
                show(announcement: message, for: 5)
            default:
                break
            }
        }
        // Animated and physical effects are the viewport's job.
        pendingEffects.append(contentsOf: effects)
    }

    /// Called by the viewport once it has consumed the queue.
    public func drainEffects() -> [EventAction] {
        let effects = pendingEffects
        pendingEffects = []
        return effects
    }

    private func show(announcement message: String, for duration: Double) {
        announcementTask?.cancel()
        announcement = Announcement(message: message, expiresAt: Date().addingTimeInterval(duration))
        announcementTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.announcement = nil
        }
    }

    private func appendChat(_ payload: ChatPayload) {
        chatLog.append(ChatEntry(senderName: payload.senderName, text: payload.text))
        // The overlay only shows the last handful; keeping every message of a
        // long session would grow without bound.
        if chatLog.count > 100 {
            chatLog.removeFirst(chatLog.count - 100)
        }
    }

    private func applyRemoteTransform(_ payload: PlayerTransformPayload) {
        guard let index = roster.firstIndex(where: { $0.peerID == payload.peerID }) else { return }
        roster[index].position = payload.position
        roster[index].yawDegrees = payload.yawDegrees
        roster[index].velocity = payload.velocity
        roster[index].isGrounded = payload.isGrounded
    }

    // MARK: Solo

    /// Starts a single-player round with no listener and no advertisement.
    ///
    /// Solo play still goes through `AbloxHost` so that rules, scoring and
    /// respawns behave exactly as they do in multiplayer — there is no second
    /// "offline" implementation of the game to drift out of sync.
    public func startSoloSession(world: WorldDocument) {
        startHosting(world: world, capacity: 1)
    }

    public var localPlayer: PlayerSnapshot? {
        roster.first { $0.peerID == localPeerID }
    }

    public var otherPlayers: [PlayerSnapshot] {
        roster.filter { $0.peerID != localPeerID }
    }
}
