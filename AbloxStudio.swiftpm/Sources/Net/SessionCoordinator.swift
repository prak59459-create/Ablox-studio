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
        /// Dropped, but trying to get back in. Carries the progress line.
        case reconnecting(String)
        case error(String)

        public var isBusy: Bool { self == .connecting || self == .searching }

        public var isReconnecting: Bool {
            if case .reconnecting = self { return true }
            return false
        }
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

    /// What the world's script has given this player: screen GUI, camera,
    /// weapon, health, ammo. Only ever changed by effects from the host.
    @Published public private(set) var scripted = ScriptedPlayerState()

    /// The world script's errors and `print` output, newest last. Only the
    /// host sees these — it is the host's world, so the host can fix it.
    @Published public private(set) var scriptLog: [ScriptLogLine] = []

    public struct ScriptLogLine: Identifiable, Hashable {
        public let id = UUID()
        public let text: String
        public let isError: Bool
    }

    public struct ChatEntry: Identifiable, Hashable {
        public let id = UUID()
        public let senderID: PeerID
        public let senderName: String
        public let text: String
        /// True when the word filter masked something. The UI marks it, so a
        /// child can see the filter is working rather than assume the message
        /// arrived that way.
        public let wasFiltered: Bool
        public let timestamp = Date()

        public init(senderID: PeerID, senderName: String, text: String, wasFiltered: Bool = false) {
            self.senderID = senderID
            self.senderName = senderName
            self.text = text
            self.wasFiltered = wasFiltered
        }
    }

    /// Chat safety, supplied by the app's settings.
    ///
    /// Filtering happens on receipt so it covers everyone's messages, not
    /// just what this device sends — a peer running a modified client cannot
    /// opt its own messages out of your filter.
    public var moderator = ChatModerator()

    /// Muting is applied when the log is read rather than when a message
    /// arrives, so unmuting someone brings their backlog back instead of
    /// leaving a hole in the conversation.
    public var muteList = MuteList() {
        didSet { objectWillChange.send() }
    }

    /// The chat log as it should be displayed.
    public var visibleChatLog: [ChatEntry] {
        chatLog.filter { muteList.allows($0.senderID, localPeerID: localPeerID) }
    }

    public struct Announcement: Equatable {
        public let message: String
        public let expiresAt: Date
    }

    // MARK: Identity

    public let localPeerID: PeerID

    /// Who the game's own chat lines come from. A fixed id rather than the
    /// host's, so muting the host does not silence the game.
    public static let gamePeerID = PeerID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
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

    /// Drives getting back in after a drop. A host has nothing to reconnect
    /// to, so only the client side ever uses it.
    private var reconnection = ReconnectCoordinator()

    /// Who is here and where, with the same rules for host and client. See
    /// `RosterState` for the two position bugs this replaced.
    private var rosterState: RosterState
    private var reconnectTask: Task<Void, Never>?
    /// Set while a world's scripts are being pulled before hosting, so a
    /// `leave()` in the meantime cancels the start.
    private var scriptRefreshAttempt: UUID?
    private var sessionClock: Date = Date()

    private var now: Double { Date().timeIntervalSince(sessionClock) }

    public init(localPeerID: PeerID = PeerID(), profile: AvatarProfile = .default) {
        self.localPeerID = localPeerID
        self.profile = profile
        self.rosterState = RosterState(localPeerID: localPeerID)
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

        guard !isStudioSession, let source = world.scriptSource, source.updatesOnPlay else {
            beginHosting(world: world, isStudioSession: isStudioSession, capacity: capacity)
            return
        }

        // The world pulls its `.absc` files from GitHub each time it is
        // played. Fetched before the round starts, so the game begins with
        // the newest scripts rather than changing under everyone.
        self.world = world
        status = .connecting
        let attempt = UUID()
        scriptRefreshAttempt = attempt
        Task { @MainActor [weak self] in
            let refreshed = await ScriptFetcher.refresh(world)
            // Left, or started something else, while waiting.
            guard let self, self.scriptRefreshAttempt == attempt else { return }
            self.scriptRefreshAttempt = nil
            self.beginHosting(world: refreshed.world, isStudioSession: false, capacity: capacity)
            if let error = refreshed.error {
                self.scriptLog.append(ScriptLogLine(
                    text: L("Could not get the latest scripts, so the saved ones are used: {}", error), isError: true))
            } else if let result = refreshed.result, result.changedAnything {
                self.scriptLog.append(ScriptLogLine(text: L("Scripts updated from GitHub: {}", result.summary), isError: false))
            }
        }
    }

    private func beginHosting(world: WorldDocument, isStudioSession: Bool, capacity: Int) {
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
            Task { @MainActor in self?.replaceRoster(roster) }
        }

        // The host used to receive every joined player's movement and never
        // show it: its screen only refreshed on join, leave and score, so a
        // guest stood frozen at their spawn point on the host's iPad.
        host.onRemoteTransform = { [weak self] payload in
            Task { @MainActor in self?.applyRemoteTransform(payload) }
        }

        host.onChat = { [weak self] sender, payload in
            Task { @MainActor in self?.appendChat(payload, from: sender) }
        }

        host.onLocalEffects = { [weak self] effects in
            Task { @MainActor in self?.apply(effects: effects.map(\.action)) }
        }

        host.onScriptDiagnostics = { [weak self] errors, output in
            Task { @MainActor in self?.appendScriptLog(errors: errors, output: output) }
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
        sessionClock = Date()
        reconnection = ReconnectCoordinator()
        status = .connecting

        let client = AbloxClient(localPeerID: localPeerID, profile: profile)

        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .playing:
                    self.status = .active
                    self.role = .joined
                    // Back in: clear the backoff so a later drop starts from
                    // attempt one rather than inheriting this one's.
                    self.reconnection.succeeded()
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                case let .disconnected(reason):
                    self.handleDisconnect(reason)
                case .connecting, .handshaking:
                    self.status = .connecting
                case .idle:
                    break
                }
            }
        }

        client.onWorld = { [weak self] world in
            Task { @MainActor in
                // A fresh world means a fresh welcome from the host's script,
                // so whatever the last one put on screen goes first.
                self?.scripted.reset()
                self?.world = world
            }
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
            Task { @MainActor in self?.replaceRoster(roster) }
        }

        client.onTransform = { [weak self] payload in
            Task { @MainActor in self?.applyRemoteTransform(payload) }
        }

        client.onEffects = { [weak self] payload in
            Task { @MainActor in self?.apply(effects: payload.actions) }
        }

        client.onChat = { [weak self] sender, payload in
            Task { @MainActor in self?.appendChat(payload, from: sender) }
        }

        self.client = client
        client.connect(to: peer, roomCode: roomCode)
    }

    // MARK: Reconnection

    /// A drop: either start trying to get back in, or report it.
    private func handleDisconnect(_ reason: DisconnectReason) {
        guard role == .joined else {
            status = .error(reason.message)
            role = .offline
            return
        }

        // A failed *attempt* arrives here as another disconnect. Treating it
        // as a fresh drop would reset the attempt counter to one, so the
        // backoff would never escalate and the give-up would never fire — an
        // infinite retry loop that looks like it is working.
        let outcome = reconnection.isReconnecting
            ? reconnection.attemptFailed(at: now)
            : reconnection.disconnected(reason: reason, at: now)

        switch outcome {
        case .gaveUp(let reason):
            status = .error(reason.message)
            role = .offline
            stopReconnecting()
        case .waiting, .attempting:
            // The world and roster are kept on screen: coming back to the
            // world you were in beats being thrown to the lobby and having to
            // find it again.
            status = .reconnecting(reconnection.progressDescription ?? "Reconnecting…")
            startReconnecting()
        case .idle:
            break
        }
    }

    /// Polls the coordinator and makes attempts when they come due.
    ///
    /// A poll rather than a scheduled timer, because the wait can be cut short
    /// — `applicationDidBecomeActive` brings the next attempt forward, and a
    /// timer would have to be torn down and rebuilt to notice.
    private func startReconnecting() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { @MainActor [weak self] in
            while let self, self.reconnection.isReconnecting, !Task.isCancelled {
                if self.reconnection.shouldAttemptNow(at: self.now) {
                    self.status = .reconnecting(self.reconnection.progressDescription ?? "Reconnecting…")
                    if self.client?.reconnect() != true {
                        // Nothing to reconnect to — the session is gone.
                        self.reconnection.cancel()
                        self.status = .error(DisconnectReason.hostClosed.message)
                        self.role = .offline
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self?.reconnectTask = nil
        }
    }

    private func stopReconnecting() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnection.cancel()
    }

    /// Called when the app returns to the foreground.
    ///
    /// The iPad has just regained its network, so a backoff scheduled while it
    /// was asleep is pure delay. This is the single most likely moment for a
    /// session to need recovering — backgrounding is what kills the TCP
    /// connection in the first place.
    public func applicationDidBecomeActive() {
        guard reconnection.isReconnecting else { return }
        reconnection.retryImmediately(at: now)
    }

    public func leave() {
        scriptRefreshAttempt = nil
        stopReconnecting()
        host?.stop()
        host = nil
        client?.disconnect()
        client = nil
        role = .offline
        status = .idle
        rosterState.reset()
        roster = []
        pingMilliseconds = nil
        pendingEffects = []
        scripted.reset()
        scriptLog = []
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

    /// Fire, reload or a screen button. Like touches, only a report: the
    /// host's script decides what it did.
    public func send(input: PlayerInputPayload.Input) {
        switch role {
        case .hosting: host?.reportLocalInput(input)
        case .joined: client?.send(input: input)
        case .offline: break
        }
    }

    public func clearScriptLog() {
        scriptLog = []
    }

    public func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch role {
        case .hosting: host?.sendChat(trimmed)
        case .joined: client?.sendChat(trimmed)
        case .offline: appendChat(ChatPayload(senderName: profile.displayName, text: trimmed), from: localPeerID)
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
            case let .script(.chat(line)):
                // A line from the game itself, not from a person.
                appendChat(ChatPayload(senderName: L("Game"), text: line), from: SessionCoordinator.gamePeerID)
            case let .script(effect):
                scripted.apply(effect)
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

    private func appendScriptLog(errors: [ScriptError], output: [String]) {
        scriptLog.append(contentsOf: output.map { ScriptLogLine(text: $0, isError: false) })
        scriptLog.append(contentsOf: errors.map { ScriptLogLine(text: $0.description, isError: true) })
        if scriptLog.count > 50 {
            scriptLog.removeFirst(scriptLog.count - 50)
        }
    }

    private func appendChat(_ payload: ChatPayload, from sender: PeerID) {
        let filtered = moderator.filter(payload.text)
        chatLog.append(ChatEntry(
            senderID: sender,
            senderName: payload.senderName,
            text: filtered.text,
            wasFiltered: filtered.wasFiltered
        ))
        // The overlay only shows the last handful; keeping every message of a
        // long session would grow without bound.
        if chatLog.count > 100 {
            chatLog.removeFirst(chatLog.count - 100)
        }
    }

    /// Another player moved. Host and client both come through here.
    private func applyRemoteTransform(_ payload: PlayerTransformPayload) {
        rosterState.apply(payload)
        roster = rosterState.players
    }

    /// A full roster from the host (or, when hosting, from our own host).
    private func replaceRoster(_ incoming: [PlayerSnapshot]) {
        for event in rosterState.replace(with: incoming) {
            switch event {
            case let .placeLocalPlayer(at: position):
                // The host picked a spawn point for us. Going through the
                // effect queue means the viewport moves us exactly as it does
                // for a teleport pad — including telling everyone else at
                // once, since a jump in position is what dead reckoning cannot
                // predict.
                pendingEffects.append(.teleportPlayer(to: position))
            }
        }
        roster = rosterState.players
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
        rosterState.localPlayer
    }

    /// The roster without the NPCs a script created: who is actually playing,
    /// for the scoreboard.
    public var people: [PlayerSnapshot] {
        roster.filter { !$0.isNPC }
    }

    /// How the local avatar should look: as the host last said, since a
    /// script can recolour or resize it, or as set up here until then.
    public var localAppearance: AvatarProfile {
        localPlayer?.profile ?? profile
    }

    public var otherPlayers: [PlayerSnapshot] {
        rosterState.otherPlayers
    }
}
