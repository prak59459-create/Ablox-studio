import Foundation
import Network

/// Hosts a session: advertises over Bonjour, accepts TLS connections, and
/// relays the world and player state between everyone connected.
///
/// The host is authoritative for **rules, scores and the world's script**
/// (`GameRuntime`) and a relay for **avatar transforms**. See
/// `docs/networking.md` for why.
public final class AbloxHost {

    public enum State: Equatable {
        case idle
        case starting
        case hosting(port: UInt16)
        case failed(String)
    }

    // MARK: Configuration

    public struct Configuration {
        public var worldName: String
        public var hostName: String
        public var capacity: Int
        public var roomCode: String
        /// `true` when Studio is hosting a co-editing session rather than a
        /// game; changes what the lobby badge says and disables the rule
        /// engine.
        public var isStudioSession: Bool
        /// A public room advertises its code, so anyone nearby can join from
        /// the list. A private one keeps it off the air: only someone the
        /// host tells can get in.
        public var isPublic: Bool
        /// Ask the host before anyone joins.
        public var needsApproval: Bool
        /// Mixed into the key made from the room code, new every session;
        /// advertised, not secret. See `TLSPeerSecurity`.
        public let keySalt: String

        public init(
            worldName: String,
            hostName: String,
            capacity: Int = AbloxProtocol.defaultCapacity,
            roomCode: String = RoomCode.generate(),
            isStudioSession: Bool = false,
            isPublic: Bool = false,
            needsApproval: Bool = false
        ) {
            self.worldName = worldName
            self.hostName = hostName
            self.capacity = capacity
            self.roomCode = roomCode
            self.isStudioSession = isStudioSession
            self.isPublic = isPublic && !isStudioSession
            self.needsApproval = needsApproval && !isStudioSession
            self.keySalt = TLSPeerSecurity.newSalt()
        }
    }

    // MARK: Callbacks

    /// Called on the host's queue whenever the roster changes.
    public var onRosterChange: (([PlayerSnapshot]) -> Void)?
    /// A joined player moved. Without this the host's own screen never saw
    /// it — the transform was stored and relayed to everyone except the one
    /// device running the host.
    public var onRemoteTransform: ((PlayerTransformPayload) -> Void)?
    /// Effects the rule engine produced, for the host's own client to apply.
    public var onLocalEffects: (([EventMachine.Effect]) -> Void)?
    /// Sender is passed alongside the payload so the UI can offer a mute
    /// control; a display name is not an identity.
    public var onChat: ((PeerID, ChatPayload) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// A world edit arrived from a co-editing peer.
    public var onRemoteDelta: ((WorldDelta) -> Void)?
    /// Problems in the world's script, and what it printed. Shown on the
    /// host's screen only: the host is the one who can fix the world.
    public var onScriptDiagnostics: (([ScriptError], [String]) -> Void)?
    /// Someone is asking to join (the room asks first): their id and name.
    public var onJoinRequest: ((PeerID, String) -> Void)?
    /// A request was answered, timed out or gave up.
    public var onJoinRequestEnded: ((PeerID) -> Void)?
    /// The room changed: ready, the vote, who is quieted.
    public var onRoomState: ((RoomState) -> Void)?
    /// A whisper for the host's own player: from, name, text.
    public var onWhisper: ((PeerID, String, String) -> Void)?
    /// The world's leaderboards changed: the host's iPad keeps them.
    public var onLeaderboards: (([String: Leaderboard]) -> Void)?

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public let localPeerID: PeerID
    public private(set) var configuration: Configuration

    private let queue = DispatchQueue(label: "com.ablox.host", qos: .userInitiated)
    private let codec: PacketCodec
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: PeerConnection] = [:]
    /// Connections that have finished the Ablox handshake and are playing.
    private var joined: Set<ObjectIdentifier> = []
    /// How much each connection may still send — see `PacketBudget`.
    private var budgets: [ObjectIdentifier: PacketBudget] = [:]
    /// Addresses that keep failing to get in.
    private var attempts = AttemptLimiter()

    /// Connections still getting in at once, and how long one may take. A
    /// connection that never finishes its handshake would otherwise hold its
    /// place forever.
    private static let maximumPending = 6
    private static let handshakeDeadline: Double = 10
    /// How long someone waits at the door for the host to answer.
    private static let approvalDeadline: Double = 60

    /// Ready, the vote, who is quieted — see `RoomState`.
    private var room = RoomState()
    /// Taken out by the host: not back in until a new room.
    private var removedPeers: Set<PeerID> = []
    /// Let in once already: a reconnect does not ask again.
    private var approvedPeers: Set<PeerID> = []
    /// At the door, waiting for the host: their handshake, kept.
    private var awaitingApproval: [ObjectIdentifier: HandshakePayload] = [:]
    private let game: GameRuntime
    private var localProfile: AvatarProfile
    private var tickTimer: DispatchSourceTimer?
    private let startedAt = Date()

    // MARK: Init

    public init(world: WorldDocument, configuration: Configuration, localPeerID: PeerID, localProfile: AvatarProfile,
                alreadyApproved: [PeerID] = []) {
        self.configuration = configuration
        self.localPeerID = localPeerID
        self.localProfile = localProfile
        self.codec = PacketCodec(localPeerID: localPeerID)
        self.game = GameRuntime(world: world, startTime: 0, seed: UInt64.random(in: 1...UInt64.max))

        // The host is a player too.
        game.addPlayer(PlayerSnapshot(peerID: localPeerID, profile: localProfile))
        approvedPeers = Set(alreadyApproved)
        room.needsApproval = configuration.needsApproval
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        state = .starting
        do {
            let parameters = TLSPeerSecurity.parameters(roomCode: configuration.roomCode, salt: configuration.keySalt)
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: AbloxProtocol.preferredPort) ?? .any)

            listener.service = NWListener.Service(
                name: configuration.hostName,
                type: AbloxProtocol.bonjourServiceType,
                txtRecord: txtRecord()
            )

            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.state = .hosting(port: self.listener?.port?.rawValue ?? 0)
                    self.startTicking()
                case let .failed(error):
                    self.state = .failed(PeerConnection.describe(error))
                    self.stop()
                case .cancelled:
                    self.state = .idle
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed("Could not start hosting: \(error.localizedDescription)")
        }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        tickTimer?.cancel()
        tickTimer = nil
        for connection in connections.values {
            connection.sendEmpty(.leave)
            connection.cancel()
        }
        connections.removeAll()
        joined.removeAll()
        budgets.removeAll()
        awaitingApproval.removeAll()
        listener?.cancel()
        listener = nil
        state = .idle
    }

    /// Bonjour TXT record, so the lobby can show world name and player count
    /// without anyone having to connect first.
    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[AbloxProtocol.TXTKey.worldName] = configuration.worldName
        txt[AbloxProtocol.TXTKey.hostName] = configuration.hostName
        txt[AbloxProtocol.TXTKey.players] = String(game.players.count)
        txt[AbloxProtocol.TXTKey.capacity] = String(configuration.capacity)
        txt[AbloxProtocol.TXTKey.mode] = configuration.isStudioSession ? "studio" : "play"
        txt[AbloxProtocol.TXTKey.protocolVersion] = String(AbloxProtocol.version)
        txt[AbloxProtocol.TXTKey.access] = configuration.isPublic ? "public" : "private"
        txt[AbloxProtocol.TXTKey.salt] = configuration.keySalt
        if configuration.isPublic {
            // The code is still the encryption key; publishing it is what
            // "public" means. Anyone who can see the room can open it.
            txt[AbloxProtocol.TXTKey.code] = configuration.roomCode
        }
        txt[AbloxProtocol.TXTKey.hostID] = RoomTag.short(localPeerID)
        let people = game.roster.filter { !$0.isNPC }.map(\.peerID)
        txt[AbloxProtocol.TXTKey.people] = RoomTag(players: people).text
        if configuration.needsApproval { txt[AbloxProtocol.TXTKey.approval] = "1" }
        return txt
    }

    /// Opens the room to everyone nearby, or closes it to all but those who
    /// have the code. Players already inside stay.
    public func setPublic(_ isPublic: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let value = isPublic && !self.configuration.isStudioSession
            guard value != self.configuration.isPublic else { return }
            self.configuration.isPublic = value
            self.refreshAdvertisement()
        }
    }

    private func refreshAdvertisement() {
        listener?.service = NWListener.Service(
            name: configuration.hostName,
            type: AbloxProtocol.bonjourServiceType,
            txtRecord: txtRecord()
        )
    }

    // MARK: Connections

    private func accept(_ nwConnection: NWConnection) {
        guard game.players.count < configuration.capacity else {
            // Full. Closing immediately is clearer than letting the handshake
            // hang; the joining player sees "that world is full".
            nwConnection.cancel()
            return
        }

        let peer = PeerConnection(adopting: nwConnection, codec: codec, queue: queue)
        let address = peer.remoteAddress
        let pending = connections.count - joined.count
        guard !attempts.isBanned(address, at: elapsed), pending < Self.maximumPending else {
            nwConnection.cancel()
            return
        }
        let key = ObjectIdentifier(peer)
        connections[key] = peer
        budgets[key] = PacketBudget()

        // Wrong code, or never saying hello: counted, and after enough of
        // them this address waits a while before it may try again.
        queue.asyncAfter(deadline: .now() + Self.handshakeDeadline) { [weak self, weak peer] in
            guard let self, let peer, self.connections[ObjectIdentifier(peer)] != nil,
                  !self.joined.contains(ObjectIdentifier(peer)),
                  self.awaitingApproval[ObjectIdentifier(peer)] == nil else { return }
            peer.cancel()
            self.dropConnection(peer)
        }

        peer.onPacket = { [weak self, weak peer] packet in
            guard let self, let peer else { return }
            self.handle(packet, from: peer)
        }

        peer.onStateChange = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            guard state.isTerminal else { return }
            self.dropConnection(peer)
        }

        peer.start()
    }

    private func dropConnection(_ peer: PeerConnection) {
        let key = ObjectIdentifier(peer)
        guard connections.removeValue(forKey: key) != nil else { return }
        budgets[key] = nil
        if let request = awaitingApproval.removeValue(forKey: key) {
            onJoinRequestEnded?(request.peerID)
        }
        let wasJoined = joined.remove(key) != nil
        if !wasJoined { attempts.recordFailure(peer.remoteAddress, at: elapsed) }
        guard wasJoined, let peerID = peer.remotePeerID else { return }
        if room.ready.remove(peerID) != nil { broadcastRoom() }
        let farewell = game.removePlayer(peerID)
        broadcast(.leave, LeavePayload(peerID: peerID))
        publishRoster()
        refreshAdvertisement()
        dispatch(farewell)
    }

    // MARK: Packet handling

    private func handle(_ packet: Packet, from peer: PeerConnection) {
        let key = ObjectIdentifier(peer)
        switch budgets[key]?.admit(packet.kind, at: elapsed) ?? .allow {
        case .allow: break
        case .drop: return
        case .disconnect:
            // Flooding: broken, or trying to take the room down.
            peer.cancel()
            dropConnection(peer)
            return
        }
        // Until the handshake, only the handshake means anything.
        guard packet.kind == .handshake || joined.contains(key) else { return }

        switch packet.kind {
        case .handshake:
            handleHandshake(packet, from: peer)

        case .playerTransform:
            guard let payload = try? codec.decodePayload(PlayerTransformPayload.self, from: packet) else { return }
            // A client may only move its own avatar. Without this check any
            // peer could shove everyone else around the world.
            guard payload.peerID == peer.remotePeerID else { return }
            // NaN or a position light-years away would poison every distance
            // check that touched it, here and on everyone's iPad.
            guard payload.isPlausible else { return }
            game.updateTransform(payload)
            relay(packet, excluding: peer)
            onRemoteTransform?(payload)

        case .eventTrigger:
            guard let payload = try? codec.decodePayload(EventTriggerPayload.self, from: packet) else { return }
            guard payload.peerID == peer.remotePeerID else { return }
            guard !configuration.isStudioSession else { return }
            let observation: EventMachine.Observation
            switch payload.cause {
            case .touched: observation = .touched(peer: payload.peerID, blockID: payload.blockID)
            case .tapped: observation = .tapped(peer: payload.peerID, blockID: payload.blockID)
            case .proximityEntered: observation = .proximityEntered(peer: payload.peerID, blockID: payload.blockID)
            }
            dispatch(game.handle(observation))

        case .playerInput:
            guard let payload = try? codec.decodePayload(PlayerInputPayload.self, from: packet) else { return }
            // Your own trigger finger only, like your own avatar.
            guard payload.peerID == peer.remotePeerID else { return }
            guard !configuration.isStudioSession else { return }
            dispatch(game.handle(payload.input, from: payload.peerID, at: elapsed))

        case .worldDelta:
            guard let delta = try? codec.decodePayload(WorldDelta.self, from: packet) else { return }
            guard configuration.isStudioSession else { return }
            game.apply(delta)
            relay(packet, excluding: peer)
            onRemoteDelta?(delta)

        case .chat:
            guard let payload = try? codec.decodePayload(ChatPayload.self, from: packet),
                  let sender = peer.remotePeerID else { return }
            // Who said it is the connection's peer, under the name the host
            // knows them by — never the sender's own claim, which could put
            // words over someone else's head.
            // Quieted by the host: said to no one.
            guard !room.quieted.contains(sender) else { return }
            let name = game.players[sender]?.profile.displayName ?? payload.senderName
            let verified = ChatPayload(senderName: name, text: payload.text, senderID: sender)
            if let stamped = try? codec.encode(.chat, verified) { relay(stamped, excluding: peer) }
            onChat?(sender, verified)
            if !configuration.isStudioSession {
                dispatch(game.handleChat(from: sender, text: payload.text))
            }

        case .room:
            guard let message = try? codec.decodePayload(RoomMessage.self, from: packet),
                  let sender = peer.remotePeerID else { return }
            handleRoom(message, from: sender)

        case .leave:
            dropConnection(peer)

        case .worldSnapshot, .roster, .eventEffect, .ping, .pong:
            // Host-authored kinds; a client sending one is either confused or
            // malicious. Either way, ignore it.
            break
        }
    }

    private func handleHandshake(_ packet: Packet, from peer: PeerConnection) {
        guard let payload = try? codec.decodePayload(HandshakePayload.self, from: packet) else {
            peer.cancel()
            return
        }

        guard payload.protocolVersion == AbloxProtocol.version else {
            // Tell them why before hanging up, so the joining iPad can show
            // something better than "connection lost".
            peer.send(.chat, ChatPayload(
                senderName: "Ablox",
                text: WireError.protocolMismatch(local: AbloxProtocol.version, remote: payload.protocolVersion)
                    .errorDescription ?? "Version mismatch"
            ))
            peer.cancel()
            return
        }
        // Nobody may join as the host, and a connection keeps the identity
        // of its first handshake.
        guard payload.peerID != localPeerID, payload.peerID == peer.remotePeerID else {
            peer.cancel()
            dropConnection(peer)
            return
        }
        let profile = payload.profile.sanitizedForNetwork()
        let key = ObjectIdentifier(peer)

        // Already playing: this is a new look, not a new arrival. Resending
        // the world here used to wipe the game's screen on their iPad.
        if joined.contains(key) {
            dispatch(game.addPlayer(PlayerSnapshot(peerID: payload.peerID, profile: profile)))
            publishRoster()
            return
        }
        // At the door already: the answer is still coming.
        guard awaitingApproval[key] == nil else { return }

        // Taken out of this room by the host.
        if removedPeers.contains(payload.peerID) {
            peer.send(.room, RoomMessage.removed)
            closeSoon(peer)
            return
        }

        // The host asks first — except for someone already let in, coming
        // back after a drop.
        if configuration.needsApproval, !approvedPeers.contains(payload.peerID) {
            var request = payload
            request.profile = profile
            awaitingApproval[key] = request
            peer.send(.room, RoomMessage.waitingForHost)
            onJoinRequest?(payload.peerID, profile.displayName)
            queue.asyncAfter(deadline: .now() + Self.approvalDeadline) { [weak self, weak peer] in
                guard let self, let peer, self.awaitingApproval[ObjectIdentifier(peer)] != nil else { return }
                self.refuse(peer)
            }
            return
        }
        admit(peer, peerID: payload.peerID, profile: profile)
    }

    /// Into the game: the host's details, the world, everyone, the room.
    private func admit(_ peer: PeerConnection, peerID: PeerID, profile: AvatarProfile) {
        let key = ObjectIdentifier(peer)
        joined.insert(key)
        approvedPeers.insert(peerID)
        attempts.recordSuccess(peer.remoteAddress)

        let welcome = game.addPlayer(PlayerSnapshot(peerID: peerID, profile: profile))

        // Reply with our own details, then the world, then the roster —
        // in that order, so the client can render the world before it has to
        // place anyone in it. The script's welcome (a weapon, a camera, the
        // screen GUI) goes last: a client throws effects away until it has a
        // world to apply them to.
        peer.send(.handshake, HandshakePayload(
            peerID: localPeerID,
            profile: localProfile,
            worldName: configuration.worldName,
            isHost: true,
            capacity: configuration.capacity
        ))
        peer.send(.worldSnapshot, game.world)
        publishRoster()
        room.clock = elapsed
        peer.send(.room, RoomMessage.state(room))
        refreshAdvertisement()
        dispatch(welcome)
    }

    private func refuse(_ peer: PeerConnection) {
        if let request = awaitingApproval.removeValue(forKey: ObjectIdentifier(peer)) {
            onJoinRequestEnded?(request.peerID)
        }
        peer.send(.room, RoomMessage.refused)
        closeSoon(peer)
    }

    /// A moment for the last message to go before the line is cut.
    private func closeSoon(_ peer: PeerConnection) {
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.cancel()
            self.dropConnection(peer)
        }
    }

    // MARK: The room

    private func handleRoom(_ message: RoomMessage, from sender: PeerID) {
        switch message {
        case let .ready(flag):
            let changed = flag ? room.ready.insert(sender).inserted : room.ready.remove(sender) != nil
            if changed { broadcastRoom() }
        case let .vote(pollID, choice):
            guard room.poll?.id == pollID, room.poll?.vote(sender, choice: choice) == true else { return }
            broadcastRoom()
        case let .whisper(target, text):
            deliverWhisper(from: sender, to: target, text: text)
        case .state, .whispered, .waitingForHost, .refused, .removed, .moving:
            // The host's to send, not a guest's.
            break
        }
    }

    private func deliverWhisper(from sender: PeerID, to target: PeerID, text: String) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AbloxProtocol.maxChatLength))
        guard !clean.isEmpty, sender != target, !room.quieted.contains(sender) else { return }
        let name = sender == localPeerID ? localProfile.displayName : (game.players[sender]?.profile.displayName ?? "")
        if target == localPeerID {
            onWhisper?(sender, name, clean)
        } else if let connection = connections.values.first(where: { $0.remotePeerID == target }),
                  joined.contains(ObjectIdentifier(connection)) {
            connection.send(.room, RoomMessage.whispered(from: sender, name: name, text: clean))
        }
    }

    private func broadcastRoom() {
        room.clock = elapsed
        broadcast(.room, RoomMessage.state(room))
        onRoomState?(room)
    }

    /// Lets someone at the door in, or not.
    public func answerJoinRequest(from peerID: PeerID, allow: Bool) {
        queue.async { [weak self] in
            guard let self,
                  let entry = self.awaitingApproval.first(where: { $0.value.peerID == peerID }),
                  let peer = self.connections[entry.key] else { return }
            if allow {
                self.awaitingApproval[entry.key] = nil
                self.onJoinRequestEnded?(peerID)
                self.admit(peer, peerID: entry.value.peerID, profile: entry.value.profile)
            } else {
                self.refuse(peer)
            }
        }
    }

    /// Takes a player out of the room. They cannot come back into it.
    public func remove(_ peerID: PeerID) {
        queue.async { [weak self] in
            guard let self, peerID != self.localPeerID else { return }
            self.removedPeers.insert(peerID)
            self.approvedPeers.remove(peerID)
            guard let peer = self.connections.values.first(where: { $0.remotePeerID == peerID }) else { return }
            peer.send(.room, RoomMessage.removed)
            self.closeSoon(peer)
        }
    }

    /// Quiets a player for everyone: their chat and whispers go nowhere.
    public func setQuieted(_ peerID: PeerID, _ quiet: Bool) {
        queue.async { [weak self] in
            guard let self, peerID != self.localPeerID else { return }
            let changed = quiet ? self.room.quieted.insert(peerID).inserted : self.room.quieted.remove(peerID) != nil
            if changed { self.broadcastRoom() }
        }
    }

    public func setNeedsApproval(_ ask: Bool) {
        queue.async { [weak self] in
            guard let self, !self.configuration.isStudioSession else { return }
            self.configuration.needsApproval = ask
            self.room.needsApproval = ask
            // Everyone already inside counts as let in.
            for connection in self.connections.values where self.joined.contains(ObjectIdentifier(connection)) {
                if let id = connection.remotePeerID { self.approvedPeers.insert(id) }
            }
            self.refreshAdvertisement()
            self.broadcastRoom()
        }
    }

    public func setAllowsWarp(_ allow: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.room.allowsWarp = allow
            self.broadcastRoom()
        }
    }

    /// The host's own "ready".
    public func setReady(_ ready: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handleRoom(.ready(ready), from: self.localPeerID)
        }
    }

    /// Everyone back to not ready, for the next round.
    public func clearReady() {
        queue.async { [weak self] in
            guard let self, !self.room.ready.isEmpty else { return }
            self.room.ready.removeAll()
            self.broadcastRoom()
        }
    }

    /// Asks everyone a question; the answers close after `seconds`.
    public func startPoll(question: String, options: [String], seconds: Double = Poll.defaultSeconds) {
        queue.async { [weak self] in
            guard let self, let poll = Poll(question: question, options: options, closesAt: self.elapsed + seconds) else { return }
            self.room.poll = poll
            self.broadcastRoom()
        }
    }

    public func endPoll() {
        queue.async { [weak self] in
            guard let self, self.room.poll != nil else { return }
            self.room.poll?.close()
            self.broadcastRoom()
        }
    }

    public func clearPoll() {
        queue.async { [weak self] in
            guard let self, self.room.poll != nil else { return }
            self.room.poll = nil
            self.broadcastRoom()
        }
    }

    /// The host's own vote.
    public func vote(poll: UUID, choice: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.handleRoom(.vote(poll: poll, choice: choice), from: self.localPeerID)
        }
    }

    public func whisper(to target: PeerID, text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deliverWhisper(from: self.localPeerID, to: target, text: text)
        }
    }

    /// Puts players on teams (the host's team picker).
    public func assignTeams(_ teams: [PeerID: String]) {
        queue.async { [weak self] in
            guard let self, !self.configuration.isStudioSession else { return }
            self.game.assignTeams(teams)
            self.dispatch([])
        }
    }

    /// Tells everyone the room is moving to `move.newHost`, then closes.
    /// The new host opens the same room code; everyone else follows.
    ///
    /// Holds on to itself until then: the app lets go of its host at once.
    public func handOver(_ move: HostMove) {
        queue.async {
            self.broadcast(.room, RoomMessage.moving(move))
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.stopOnQueue() }
        }
    }

    /// For the QR code and invitation: this room's port and salt.
    public var listeningPort: UInt16? { listener?.port?.rawValue }
    public var keySalt: String { configuration.keySalt }

    // MARK: Broadcasting

    /// To everyone playing. A connection still getting in is sent nothing
    /// until its handshake: it would throw it away, and it has not yet shown
    /// it belongs here.
    private func relay(_ packet: Packet, excluding sender: PeerConnection?) {
        for (key, connection) in connections where connection !== sender && joined.contains(key) {
            connection.send(packet)
        }
    }

    private func broadcast<T: Encodable>(_ kind: PacketKind, _ payload: T) {
        guard let packet = try? codec.encode(kind, payload) else { return }
        relay(packet, excluding: nil)
    }

    private func publishRoster() {
        let roster = game.roster
        broadcast(.roster, RosterPayload(players: roster))
        onRosterChange?(roster)
    }

    /// Routes resolved effects: shared ones to everyone, personal ones only to
    /// the player they concern.
    private func dispatch(_ effects: [EventMachine.Effect]) {
        reportScriptDiagnostics()
        // The map and the roster first: an effect may be about a block the
        // script has only just created, or an NPC that only just appeared.
        sendWorldChanges()
        defer { sendNPCMovement() }
        guard !effects.isEmpty else { return }
        let (broadcastPayload, targeted) = EventMachine.payloads(grouping: effects)

        if let broadcastPayload {
            broadcast(.eventEffect, broadcastPayload)
        }

        for (peerID, payload) in targeted {
            if peerID == localPeerID {
                continue
            }
            guard let packet = try? codec.encode(.eventEffect, payload) else { continue }
            connections.values
                .first { $0.remotePeerID == peerID }?
                .send(packet)
        }

        // The host renders its own world too, so hand it everything that
        // concerns it.
        let localEffects = effects.filter { $0.targetPeerID == nil || $0.targetPeerID == localPeerID }
        if !localEffects.isEmpty {
            onLocalEffects?(localEffects)
        }

        // A score change may have shifted the leaderboard.
        if effects.contains(where: { if case .awardPoints = $0.action { return true }; return false }) {
            publishRoster()
        }
    }

    // MARK: Local player

    /// Called by the host's own game loop, so the host's avatar is replicated
    /// exactly like everyone else's.
    public func publishLocalTransform(_ snapshot: PlayerSnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            self.game.updateTransform(PlayerTransformPayload(snapshot: snapshot))
            self.broadcast(.playerTransform, PlayerTransformPayload(snapshot: snapshot))
        }
    }

    public func reportLocalObservation(_ observation: EventMachine.Observation) {
        queue.async { [weak self] in
            guard let self, !self.configuration.isStudioSession else { return }
            self.dispatch(self.game.handle(observation))
        }
    }

    /// The host's own fire button and screen buttons. Checked by the same
    /// rules as everyone else's — the host gets no shortcut.
    public func reportLocalInput(_ input: PlayerInputPayload.Input) {
        queue.async { [weak self] in
            guard let self, !self.configuration.isStudioSession else { return }
            self.dispatch(self.game.handle(input, from: self.localPeerID, at: self.elapsed))
        }
    }

    public func sendChat(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let payload = ChatPayload(senderName: self.localProfile.displayName, text: text, senderID: self.localPeerID)
            self.broadcast(.chat, payload)
            self.onChat?(self.localPeerID, payload)
            if !self.configuration.isStudioSession {
                self.dispatch(self.game.handleChat(from: self.localPeerID, text: text))
            }
        }
    }

    /// Pushes a Studio edit to co-editing peers.
    public func publish(delta: WorldDelta) {
        queue.async { [weak self] in
            guard let self else { return }
            self.game.apply(delta)
            self.broadcast(.worldDelta, delta)
        }
    }

    public func startRound() {
        queue.async { [weak self] in
            guard let self else { return }
            self.dispatch(self.game.handle(.roundStarted))
        }
    }

    public func updateLocalProfile(_ profile: AvatarProfile) {
        queue.async { [weak self] in
            guard let self else { return }
            self.localProfile = profile
            self.dispatch(self.game.addPlayer(PlayerSnapshot(peerID: self.localPeerID, profile: profile)))
            self.publishRoster()
        }
    }

    // MARK: Tick

    /// Drives timers, proximity and the kill plane. Runs at 10 Hz — these are
    /// all "did something become true" checks, not simulation, so the render
    /// frame rate would be wasted precision.
    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dispatch(self.game.advance(to: self.elapsed))
            if var poll = self.room.poll, poll.closeIfDue(at: self.elapsed) {
                self.room.poll = poll
                self.broadcastRoom()
            }
        }
        timer.resume()
        tickTimer = timer
    }

    /// Seconds since the host started: the one clock the rules, the script
    /// and every shot are measured against. Time spent paused (playing
    /// alone) does not count, so a timer resumes where it stopped.
    private var elapsed: Double {
        let now = pausedAt ?? Date()
        return now.timeIntervalSince(startedAt) - pausedTotal
    }

    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    /// Stops or restarts the game's clock. Only for a game with nobody else
    /// in it — pausing everyone's game from one iPad would be a trick.
    public func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self, self.joined.isEmpty else { return }
            if paused, self.pausedAt == nil {
                self.pausedAt = Date()
            } else if !paused, let since = self.pausedAt {
                self.pausedTotal += Date().timeIntervalSince(since)
                self.pausedAt = nil
            }
        }
    }

    /// Blocks and settings the script changed, to everyone's copy of the
    /// world — including this iPad's own screen.
    private func sendWorldChanges() {
        for delta in game.drainWorldDeltas() {
            broadcast(.worldDelta, delta)
            onRemoteDelta?(delta)
        }
        if game.takeRosterChange() { publishRoster() }
        if let boards = game.takeLeaderboardsIfChanged() { onLeaderboards?(boards) }
    }

    /// The leaderboards kept from earlier games, before the round starts.
    public func loadLeaderboards(_ boards: [String: Leaderboard]) {
        queue.async { [weak self] in self?.game.loadLeaderboards(boards) }
    }

    /// NPCs are moved by the host, so their movement goes out like any
    /// player's — the same packet, the same smoothing on arrival.
    private func sendNPCMovement() {
        for transform in game.drainNPCTransforms() {
            broadcast(.playerTransform, transform)
            onRemoteTransform?(transform)
        }
    }

    private func reportScriptDiagnostics() {
        guard let onScriptDiagnostics else { return }
        let errors = game.drainErrors()
        let output = game.drainOutput()
        guard !errors.isEmpty || !output.isEmpty else { return }
        onScriptDiagnostics(errors, output)
    }

    // MARK: Introspection

    public var roomCode: String { configuration.roomCode }

    public var connectedCount: Int {
        connections.count
    }
}
