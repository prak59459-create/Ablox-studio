import Foundation
import Combine
import Network
import AbloxCore

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
    /// The world being played, as it is right now.
    ///
    /// Changes from the game are applied to it in place as they arrive, many
    /// a second in a busy game. SwiftUI is told at most ten times a second —
    /// the play screen only shows its name and its map — while the 3D view
    /// reads it, and which blocks changed (`takeWorldChanges`), every frame.
    /// It used to be published on every change, which copied the whole world
    /// and rebuilt the whole play screen each time.
    public private(set) var world: WorldDocument {
        get { liveWorld }
        set {
            objectWillChange.send()
            liveWorld = newValue
            worldChanges.noteEverything()
        }
    }
    private var liveWorld: WorldDocument = .blank()
    /// Which blocks changed since the 3D view last looked.
    private var worldChanges = WorldChangeLog()
    /// Changes and movement from the network's queue, applied in one go.
    private let deltaInbox = WorldDeltaInbox()
    private let transformInbox = TransformInbox()
    /// Telling SwiftUI about the world and where everyone is: ten times a second.
    private var quietPublishing = PublishThrottle(interval: 0.1)
    private var rosterIsBehind = false
    @Published public private(set) var roster: [PlayerSnapshot] = []
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var chatLog: [ChatEntry] = []
    @Published public private(set) var announcement: Announcement?
    @Published public private(set) var pingMilliseconds: Double?
    @Published public private(set) var roomCode: String = ""
    /// While hosting: whether the room is open to everyone nearby (public)
    /// or only to people with the code (private).
    @Published public private(set) var isRoomPublic: Bool = false
    @Published public private(set) var browserUnavailableReason: String?

    /// Effects the local renderer still has to apply (tints, moves, sounds).
    /// The viewport drains this each frame. Not published: nothing on screen
    /// is drawn from it, and publishing it made SwiftUI rebuild the play
    /// screen every frame when the viewport emptied it.
    public private(set) var pendingEffects: [EventAction] = []

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
        /// A whisper: only the two of them see it, and it gets no bubble.
        /// Names the other person — who it came from, or who it went to.
        public let privateWith: String?

        public var isPrivate: Bool { privateWith != nil }

        public init(senderID: PeerID, senderName: String, text: String, wasFiltered: Bool = false, privateWith: String? = nil) {
            self.senderID = senderID
            self.senderName = senderName
            self.text = text
            self.wasFiltered = wasFiltered
            self.privateWith = privateWith
        }
    }

    /// Where games keep what they save for this iPad's player (`p.save`),
    /// supplied by the app. Nil — Studio's play tests — saves nothing, so
    /// trying a game out never touches someone's real progress.
    public var saveStore: GameSaveStore?

    /// Chat safety, supplied by the app's settings.
    ///
    /// Filtering happens on receipt so it covers everyone's messages, not
    /// just what this device sends — a peer running a modified client cannot
    /// opt its own messages out of your filter.
    public var moderator = ChatModerator()

    /// Family: only these people's lines are kept (friends only); nil for
    /// everyone. The game's own lines and this player's always are.
    public var chatOnlyFrom: Set<PeerID>?

    /// How lines are tidied as they arrive: personal details hidden,
    /// shouting softened, long runs of one letter cut (Chat options).
    public var chatOptions = ChatOptions()

    /// False when Settings → Family has chat off: other players' lines are
    /// neither shown nor sent. The game's own lines and NPCs still speak.
    public var allowsPlayerChat = true

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

    /// Something the game said — a banner or a line from the game — kept
    /// so a player who missed it can read it again.
    public struct LogEntry: Identifiable, Equatable {
        public let id = UUID()
        public let date: Date
        public let text: String
    }

    /// The last fifty things the game said, oldest first.
    @Published public private(set) var messageLog: [LogEntry] = []

    /// Playing alone: nobody can join, and the game can really pause.
    @Published public private(set) var isSolo = false
    @Published public private(set) var isPaused = false

    // MARK: The room

    /// Ready, the vote, who the host quieted, warping, asking to join.
    @Published public private(set) var roomState = RoomState()
    /// When the vote in progress closes, on this iPad's clock.
    @Published public private(set) var pollEndsAt: Date?
    /// Hosting: people at the door, waiting for an answer.
    @Published public private(set) var joinRequests: [JoinRequest] = []
    /// Joining: the host asks first, and has not answered yet.
    @Published public private(set) var isWaitingForHost = false
    /// The room is moving to another iPad (the host left).
    @Published public private(set) var roomMove: HostMove?

    public struct JoinRequest: Identifiable, Hashable {
        public let id: PeerID
        public let name: String
    }

    /// Settings → Family: whispers only with full chat.
    public var allowsWhispers = true

    /// The host quieted this player: nothing they say goes anywhere.
    public var isQuietedByHost: Bool { roomState.quieted.contains(localPeerID) }

    /// The port the room is open on while hosting, for the invitation.
    private var hostingPort: UInt16?

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

    public func startHosting(world: WorldDocument, isStudioSession: Bool = false, isPublic: Bool = false, capacity: Int = AbloxProtocol.defaultCapacity) {
        roomMove = nil
        leave()

        guard !isStudioSession, let source = world.scriptSource, source.updatesOnPlay else {
            beginHosting(world: world, isStudioSession: isStudioSession, isPublic: isPublic, capacity: capacity)
            return
        }

        // The world pulls its `.absc` files from GitHub each time it is
        // played. Fetched before the round starts, so the game begins with
        // the newest scripts rather than changing under everyone.
        enter(world)
        status = .connecting
        let attempt = UUID()
        scriptRefreshAttempt = attempt
        Task { @MainActor [weak self] in
            let refreshed = await ScriptFetcher.refresh(world)
            // Left, or started something else, while waiting.
            guard let self, self.scriptRefreshAttempt == attempt else { return }
            self.scriptRefreshAttempt = nil
            self.beginHosting(world: refreshed.world, isStudioSession: false, isPublic: isPublic, capacity: capacity)
            if let error = refreshed.error {
                self.scriptLog.append(ScriptLogLine(
                    text: L("Could not get the latest scripts, so the saved ones are used: {}", error), isError: true))
            } else if let result = refreshed.result, result.changedAnything {
                self.scriptLog.append(ScriptLogLine(text: L("Scripts updated from GitHub: {}", result.summary), isError: false))
            }
        }
    }

    private func beginHosting(world: WorldDocument, isStudioSession: Bool, isPublic: Bool, capacity: Int,
                              roomCode existingCode: String? = nil, needsApproval: Bool = false, alreadyApproved: [PeerID] = []) {
        enter(world)
        let code = existingCode ?? RoomCode.generate()
        roomCode = code

        let configuration = AbloxHost.Configuration(
            worldName: world.name,
            hostName: profile.displayName.isEmpty ? "Ablox" : "\(profile.displayName)'s iPad",
            capacity: capacity,
            roomCode: code,
            isStudioSession: isStudioSession,
            isPublic: isPublic,
            needsApproval: needsApproval
        )
        isRoomPublic = configuration.isPublic

        let host = AbloxHost(world: world, configuration: configuration, localPeerID: localPeerID, localProfile: profile,
                             alreadyApproved: alreadyApproved)

        host.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case let .hosting(port):
                    self.status = .active
                    self.role = .hosting
                    self.hostingPort = port
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
        let hostTransforms = transformInbox
        host.onRemoteTransform = { [weak self] payload in
            guard hostTransforms.add(payload) else { return }
            Task { @MainActor in self?.receiveTransforms() }
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

        host.onRoomState = { [weak self] state in
            Task { @MainActor in self?.receive(state) }
        }

        host.onJoinRequest = { [weak self] peer, name in
            Task { @MainActor in
                guard let self, !self.joinRequests.contains(where: { $0.id == peer }) else { return }
                self.joinRequests.append(JoinRequest(id: peer, name: name))
            }
        }

        host.onJoinRequestEnded = { [weak self] peer in
            Task { @MainActor in self?.joinRequests.removeAll { $0.id == peer } }
        }

        host.onWhisper = { [weak self] sender, name, text in
            Task { @MainActor in self?.receiveWhisper(from: sender, name: name, text: text) }
        }

        let deltas = deltaInbox
        host.onRemoteDelta = { [weak self] delta in
            guard deltas.add(delta) else { return }
            Task { @MainActor in self?.receiveWorldChanges() }
        }

        let boards = LeaderboardStore()
        let worldID = world.id
        host.loadLeaderboards(boards.load(worldID: worldID))
        host.onLeaderboards = { changed in
            DispatchQueue.global(qos: .utility).async { boards.save(changed, worldID: worldID) }
        }

        self.host = host
        host.start()
        host.startRound()
        // The host plays too: its own saved data goes in the same way a
        // guest's does, straight after the round it will read it in.
        if let saved = savedData(for: world) { host.reportLocalInput(.saved(saved)) }
    }

    /// Switches the room between public and private while hosting.
    public func setRoomPublic(_ isPublic: Bool) {
        guard let host, !host.configuration.isStudioSession else { return }
        isRoomPublic = isPublic
        host.setPublic(isPublic)
    }

    // MARK: Joining

    public func join(_ peer: DiscoveredPeer, roomCode code: String) {
        roomMove = nil
        guard peer.isCompatible else {
            status = .error(peer.isNewer
                ? L("That iPad has a newer Ablox. Update this one in Settings, then join.")
                : L("That iPad has an older Ablox. It needs to update before you can join."))
            return
        }
        guard !peer.isFull else {
            status = .error("That world is full.")
            return
        }

        leave()
        roomCode = RoomCode.normalize(code)
        makeClient().connect(to: peer, roomCode: roomCode)
    }

    /// Joins with an invitation (a QR code, or text sent from the host):
    /// straight to the host's address, without the list.
    public func join(ticket: JoinTicket) {
        roomMove = nil
        leave()
        roomCode = ticket.code
        guard let port = NWEndpoint.Port(rawValue: ticket.port) else {
            status = .error(L("That invitation doesn't work."))
            return
        }
        makeClient().connect(to: .hostPort(host: NWEndpoint.Host(ticket.host), port: port), roomCode: ticket.code, salt: ticket.salt)
    }

    /// A client wired to this coordinator. Its callbacks check it is still
    /// the current one: a client being replaced — the room moving to a new
    /// host — must not report its own goodbye as a lost connection.
    private func makeClient() -> AbloxClient {
        sessionClock = Date()
        reconnection = ReconnectCoordinator()
        status = .connecting

        let client = AbloxClient(localPeerID: localPeerID, profile: profile)

        client.onStateChange = { [weak self, weak client] state in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                switch state {
                case .playing:
                    self.status = .active
                    self.role = .joined
                    self.isWaitingForHost = false
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
                guard let self else { return }
                // A fresh world means a fresh welcome from the host's script,
                // so whatever the last one put on screen goes first.
                self.scripted.reset()
                self.enter(world)
                // Now that we know which game this is, hand the host what this
                // iPad has saved in it. A reconnect sends it again; the host
                // keeps only the first copy it got for this visit.
                if let saved = self.savedData(for: world) { self.client?.send(input: .saved(saved)) }
            }
        }

        let clientDeltas = deltaInbox
        client.onDelta = { [weak self] delta in
            guard clientDeltas.add(delta) else { return }
            Task { @MainActor in self?.receiveWorldChanges() }
        }

        client.onRoster = { [weak self] roster in
            Task { @MainActor in self?.replaceRoster(roster) }
        }

        let clientTransforms = transformInbox
        client.onTransform = { [weak self] payload in
            guard clientTransforms.add(payload) else { return }
            Task { @MainActor in self?.receiveTransforms() }
        }

        client.onEffects = { [weak self] payload in
            Task { @MainActor in self?.apply(effects: payload.actions) }
        }

        client.onChat = { [weak self] sender, payload in
            Task { @MainActor in self?.appendChat(payload, from: sender) }
        }

        client.onRoom = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                switch message {
                case let .state(state):
                    self.receive(state)
                case let .whispered(from, name, text):
                    self.receiveWhisper(from: from, name: name, text: text)
                case .waitingForHost:
                    self.isWaitingForHost = true
                default:
                    break
                }
            }
        }

        client.onHostMove = { [weak self, weak client] move in
            Task { @MainActor in
                guard let self, let client, self.client === client else { return }
                self.follow(move)
            }
        }

        self.client = client
        return client
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
        moveTask?.cancel()
        moveTask = nil
        roomState = RoomState()
        pollEndsAt = nil
        joinRequests = []
        isWaitingForHost = false
        hostingPort = nil
        scriptRefreshAttempt = nil
        stopReconnecting()
        host?.stop()
        host = nil
        isRoomPublic = false
        client?.disconnect()
        client = nil
        role = .offline
        status = .idle
        rosterState.reset()
        roster = []
        rosterIsBehind = false
        pingMilliseconds = nil
        pendingEffects = []
        // Whatever was still on its way belonged to the last game.
        _ = deltaInbox.take()
        _ = transformInbox.take()
        worldChanges.noteEverything()
        scripted.reset()
        scriptLog = []
        // The last game's chat and speech bubbles belong to that game.
        chatLog = []
        messageLog = []
        isSolo = false
        isPaused = false
        announcementTask?.cancel()
        announcement = nil
    }

    // MARK: The room

    private var moveTask: Task<Void, Never>?

    private func receive(_ state: RoomState) {
        let newPoll = state.poll?.id != roomState.poll?.id || (state.poll?.isClosed == false && pollEndsAt == nil)
        roomState = state
        if let left = state.pollSecondsLeft {
            if newPoll { pollEndsAt = Date().addingTimeInterval(left) }
        } else {
            pollEndsAt = nil
        }
    }

    private func receiveWhisper(from sender: PeerID, name: String, text: String) {
        guard allowsPlayerChat, allowsWhispers, muteList.allows(sender, localPeerID: localPeerID) else { return }
        if let only = chatOnlyFrom, !only.contains(sender) { return }
        let filtered = moderator.filter(text)
        chatLog.append(ChatEntry(senderID: sender, senderName: name, text: ChatTidy.tidy(filtered.text, options: chatOptions),
                                 wasFiltered: filtered.wasFiltered, privateWith: name))
        if chatLog.count > 100 { chatLog.removeFirst(chatLog.count - 100) }
    }

    /// Says something to one player only.
    public func whisper(to target: PeerID, text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AbloxProtocol.maxChatLength))
        guard !trimmed.isEmpty, allowsPlayerChat, allowsWhispers, !isQuietedByHost, target != localPeerID else { return }
        switch role {
        case .hosting: host?.whisper(to: target, text: trimmed)
        case .joined: client?.send(room: .whisper(to: target, text: trimmed))
        case .offline: return
        }
        let name = roster.first { $0.peerID == target }?.profile.displayName ?? ""
        chatLog.append(ChatEntry(senderID: localPeerID, senderName: profile.displayName, text: trimmed, privateWith: name))
    }

    public var isReady: Bool { roomState.ready.contains(localPeerID) }

    public func setReady(_ ready: Bool) {
        switch role {
        case .hosting: host?.setReady(ready)
        case .joined: client?.send(room: .ready(ready))
        case .offline: break
        }
    }

    public func vote(choice: Int) {
        guard let poll = roomState.poll, !poll.isClosed else { return }
        switch role {
        case .hosting: host?.vote(poll: poll.id, choice: choice)
        case .joined: client?.send(room: .vote(poll: poll.id, choice: choice))
        case .offline: break
        }
    }

    /// Stands next to another player — a friend, usually. Only when the host
    /// allows it.
    public func warp(to target: PeerID) {
        guard role == .hosting || roomState.allowsWarp,
              let player = rosterState.players.first(where: { $0.peerID == target }) else { return }
        let side = Vec3(sin(player.yawDegrees * .pi / 180), 0, cos(player.yawDegrees * .pi / 180))
        pendingEffects.append(.teleportPlayer(to: player.position + side * 1.6 + Vec3(0, 0.5, 0)))
    }

    // Host only.

    public func answerJoinRequest(_ request: JoinRequest, allow: Bool) {
        joinRequests.removeAll { $0.id == request.id }
        host?.answerJoinRequest(from: request.id, allow: allow)
    }

    public func removeFromRoom(_ peer: PeerID) { host?.remove(peer) }
    public func setQuieted(_ peer: PeerID, _ quiet: Bool) { host?.setQuieted(peer, quiet) }
    public func setNeedsApproval(_ ask: Bool) { host?.setNeedsApproval(ask) }
    public func setAllowsWarp(_ allow: Bool) { host?.setAllowsWarp(allow) }
    public func clearReady() { host?.clearReady() }
    public func startPoll(question: String, options: [String]) { host?.startPoll(question: question, options: options) }
    public func endPoll() { host?.endPoll() }
    public func clearPoll() { host?.clearPoll() }
    public func assignTeams(_ teams: [PeerID: String]) { host?.assignTeams(teams) }

    /// A new round of the same game, for everyone.
    public func startNewRound() {
        host?.startRound()
        host?.clearReady()
    }

    /// Whether leaving could hand the room to someone instead of closing it.
    public var canHandOver: Bool {
        role == .hosting && !isSolo && HostMove.successor(in: people, leavingHost: localPeerID) != nil
    }

    /// Leaves, handing the room to whoever has been here longest, so the game
    /// goes on for everyone else. False when there is nobody to hand it to.
    @discardableResult
    public func handOverAndLeave() -> Bool {
        guard role == .hosting, !isSolo, let host,
              let next = HostMove.successor(in: people, leavingHost: localPeerID) else { return false }
        let move = HostMove(newHost: next.peerID, newHostName: next.profile.displayName, roomCode: roomCode,
                            isPublic: isRoomPublic, capacity: host.configuration.capacity,
                            needsApproval: roomState.needsApproval, members: people.map(\.peerID))
        host.handOver(move)
        // The host closes itself once the news has gone out.
        self.host = nil
        leave()
        return true
    }

    /// The room is moving: open it here, or go and find it on the new host.
    private func follow(_ move: HostMove) {
        roomMove = move
        let world = self.world
        let old = client
        client = nil
        old?.disconnect()
        stopReconnecting()

        if move.newHost == localPeerID {
            // This iPad is the new host: the same world, as it is now, under
            // the same code, and everyone who was in it may come straight in.
            rosterState.reset()
            roster = []
            beginHosting(world: world, isStudioSession: false, isPublic: move.isPublic, capacity: move.capacity,
                         roomCode: move.roomCode, needsApproval: move.needsApproval, alreadyApproved: move.members)
            roomMove = nil
            show(announcement: L("You are the host now."), for: 4)
            return
        }

        status = .reconnecting(L("Moving to {}'s iPad…", move.newHostName))
        browser.start()
        let wanted = RoomTag.short(move.newHost)
        moveTask?.cancel()
        moveTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(25)
            while !Task.isCancelled, Date() < deadline {
                if let self, let room = self.discoveredPeers.first(where: { $0.hostShortID == wanted && $0.isCompatible }) {
                    self.moveTask = nil
                    self.join(room, roomCode: move.roomCode)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.moveTask = nil
            self.roomMove = nil
            self.status = .error(L("Couldn't find the room on {}'s iPad.", move.newHostName))
            self.role = .offline
        }
    }

    /// An invitation to this room — its address, code and salt — for the QR
    /// code, while hosting.
    public var invitation: JoinTicket? {
        guard role == .hosting, !isSolo, let host, let port = hostingPort, let address = LocalAddress.current() else { return nil }
        return JoinTicket(host: address, port: port, salt: host.keySalt, code: roomCode, world: world.name)
    }

    /// Something went wrong putting the room on the internet, or reaching
    /// one there. The game carries on (on the router, for a host).
    public func noteCloudProblem(_ message: String) {
        if role == .hosting {
            show(announcement: L("This room couldn't go on the internet: {}", message), for: 6)
        } else {
            status = .error(L("Couldn't reach that internet room: {}", message))
        }
    }

    /// What the internet relay needs to reach this room: the listener's
    /// port, and the code, salt and size of the room.
    public var roomKeys: (port: UInt16, salt: String, code: String, capacity: Int)? {
        guard role == .hosting, let host, let port = hostingPort else { return nil }
        return (port, host.keySalt, roomCode, host.configuration.capacity)
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
    /// Waves, dances or floats an emoji over this player's head, for
    /// everyone. See `Gesture`.
    public func send(gesture: Gesture) {
        send(input: .gesture(gesture.wire))
    }

    /// Stops the game's clock while playing alone (timers, NPCs, the round).
    public func setPaused(_ paused: Bool) {
        guard isSolo, role == .hosting else { return }
        isPaused = paused
        host?.setPaused(paused)
    }

    private func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messageLog.append(LogEntry(date: Date(), text: trimmed))
        if messageLog.count > 50 { messageLog.removeFirst(messageLog.count - 50) }
    }

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

    /// Empties this iPad's chat window; nobody else's changes.
    public func clearChat() {
        chatLog = []
    }

    public func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, allowsPlayerChat, !isQuietedByHost else { return }
        switch role {
        case .hosting: host?.sendChat(trimmed)
        case .joined:
            client?.sendChat(trimmed)
            // The host relays a message to everyone but its sender, so a
            // joined player's own line — and the bubble over their own head —
            // has to be added here or it never appears on their screen.
            appendChat(ChatPayload(senderName: profile.displayName, text: trimmed), from: localPeerID)
        case .offline: appendChat(ChatPayload(senderName: profile.displayName, text: trimmed), from: localPeerID)
        }
    }

    public func publish(delta: WorldDelta) {
        objectWillChange.send()
        delta.apply(to: &liveWorld)
        worldChanges.note(delta)
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
        // Changes sent before these effects come first: a move or a fade is
        // for a block that may have only just been made.
        receiveWorldChanges()
        for action in effects {
            switch action {
            case let .announce(message, duration):
                show(announcement: message, for: duration)
            case let .setVisible(blockID, visible):
                liveWorld.mutate(id: blockID) { $0.isVisible = visible }
                worldChanges.note(block: blockID)
                publishQuietly()
            case let .setCollision(blockID, enabled):
                liveWorld.mutate(id: blockID) { $0.hasCollision = enabled }
                worldChanges.note(block: blockID)
                publishQuietly()
            case let .endRound(message):
                show(announcement: message, for: 5)
            case let .script(.chat(line)):
                // A line from the game itself, not from a person.
                appendChat(ChatPayload(senderName: L("Game"), text: line), from: SessionCoordinator.gamePeerID)
                remember(line)
            case let .script(.say(speaker, name, text)):
                // A character in the game talking: under its own name, so the
                // bubble goes over its head and it can be muted like anyone.
                appendChat(ChatPayload(senderName: name, text: text), from: speaker)
            case let .script(.store(data)):
                keep(data)
            case let .script(effect):
                scripted.apply(effect)
            default:
                break
            }
        }
        // Animated and physical effects are the viewport's job.
        pendingEffects.append(contentsOf: effects)
    }

    // MARK: Changing worlds

    /// Makes `world` the one being played. A different world than the last
    /// one also puts the local player at its spawn point — queued before
    /// anything the host's script sends, so the script can still move them —
    /// rather than wherever they stood in the previous game.
    private func enter(_ world: WorldDocument) {
        let isDifferent = world.id != self.world.id
        self.world = world
        if isDifferent {
            pendingEffects.append(.teleportPlayer(to: world.spawnPosition(forPlayerIndex: 0)))
        }
    }

    // MARK: Saved game data

    /// What this iPad has saved in `world`, or nil when saving is off or the
    /// world has no script to read it.
    private func savedData(for world: WorldDocument) -> SaveData? {
        guard let saveStore, world.hasScript else { return nil }
        return saveStore.load(worldID: saveID(for: world)) ?? SaveData()
    }

    /// Which save slot a world plays with (Games → a game's page), 1 by
    /// default. Set by the app from its settings.
    public var saveSlotFor: @MainActor (UUID) -> Int = { _ in 1 }

    private func saveID(for world: WorldDocument) -> UUID {
        SaveSlots.storageID(world: world.id, slot: saveSlotFor(world.id))
    }

    /// Writes what the host's script saved. Small and at most once a second,
    /// so it goes straight to disk rather than waiting for the app to close —
    /// an iPad that runs out of battery mid-game keeps its progress.
    private func keep(_ data: SaveData) {
        guard let saveStore, world.hasScript else { return }
        do {
            let slot = saveSlotFor(world.id)
            try saveStore.save(data, worldID: saveID(for: world), worldName: slot > 1 ? L("{} (slot {})", world.name, slot) : world.name)
        } catch {
            scriptLog.append(ScriptLogLine(text: L("Could not save this game's progress: {}", error.localizedDescription), isError: true))
        }
    }

    /// Called by the viewport once it has consumed the queue.
    public func drainEffects() -> [EventAction] {
        guard !pendingEffects.isEmpty else { return [] }
        let effects = pendingEffects
        pendingEffects = []
        return effects
    }

    // MARK: Live state for the 3D view

    /// Applies every world change waiting, in place and in order. The
    /// viewport calls this each frame too, so a change is never a frame late.
    public func receiveWorldChanges() {
        let deltas = deltaInbox.take()
        guard !deltas.isEmpty else { return }
        for delta in deltas {
            delta.apply(to: &liveWorld)
            worldChanges.note(delta)
        }
        publishQuietly()
    }

    /// Everyone's newest position, waiting from the network.
    public func receiveTransforms() {
        let payloads = transformInbox.take()
        guard !payloads.isEmpty else { return }
        for payload in payloads { rosterState.apply(payload) }
        rosterIsBehind = true
        publishQuietly()
    }

    /// Which blocks changed since the last call. The viewport's alone to take.
    public func takeWorldChanges() -> WorldChangeLog {
        worldChanges.take()
    }

    /// Everyone as they are this moment; `roster` catches up ten times a second.
    public var livePlayers: [PlayerSnapshot] {
        rosterState.players
    }

    /// Tells SwiftUI about the world and positions, at most ten times a second.
    private func publishQuietly() {
        switch quietPublishing.changed(at: ProcessInfo.processInfo.systemUptime) {
        case .now:
            publishLiveState()
        case let .after(seconds):
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                self?.publishLiveState()
            }
        case .alreadyScheduled:
            break
        }
    }

    private func publishLiveState() {
        quietPublishing.published(at: ProcessInfo.processInfo.systemUptime)
        if rosterIsBehind {
            rosterIsBehind = false
            roster = rosterState.players
        } else {
            objectWillChange.send()
        }
    }

    private func show(announcement message: String, for duration: Double) {
        remember(L(message))
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
        let isPerson = sender != SessionCoordinator.gamePeerID && !(roster.first { $0.peerID == sender }?.isNPC ?? false)
        if !allowsPlayerChat, isPerson {
            return
        }
        if isPerson, sender != localPeerID, let only = chatOnlyFrom, !only.contains(sender) {
            return
        }
        let filtered = moderator.filter(payload.text)
        // The game's own lines are left as the game wrote them.
        let text = sender == SessionCoordinator.gamePeerID ? filtered.text : ChatTidy.tidy(filtered.text, options: chatOptions)
        chatLog.append(ChatEntry(
            senderID: sender,
            senderName: payload.senderName,
            text: text,
            wasFiltered: filtered.wasFiltered
        ))
        // The overlay only shows the last handful; keeping every message of a
        // long session would grow without bound.
        if chatLog.count > 100 {
            chatLog.removeFirst(chatLog.count - 100)
        }
    }

    /// A full roster from the host (or, when hosting, from our own host).
    private func replaceRoster(_ incoming: [PlayerSnapshot]) {
        // Positions still waiting are older than this roster.
        receiveTransforms()
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
        rosterIsBehind = false
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
        isSolo = true
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
