import Foundation
import Network

/// Hosts a session: advertises over Bonjour, accepts TLS connections, and
/// relays the world and player state between everyone connected.
///
/// The host is authoritative for **rules and scores** (`EventMachine`) and a
/// relay for **avatar transforms**. See `docs/networking.md` for why.
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

        public init(
            worldName: String,
            hostName: String,
            capacity: Int = AbloxProtocol.defaultCapacity,
            roomCode: String = RoomCode.generate(),
            isStudioSession: Bool = false
        ) {
            self.worldName = worldName
            self.hostName = hostName
            self.capacity = capacity
            self.roomCode = roomCode
            self.isStudioSession = isStudioSession
        }
    }

    // MARK: Callbacks

    /// Called on the host's queue whenever the roster changes.
    public var onRosterChange: (([PlayerSnapshot]) -> Void)?
    /// Effects the rule engine produced, for the host's own client to apply.
    public var onLocalEffects: (([EventMachine.Effect]) -> Void)?
    public var onChat: ((ChatPayload) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// A world edit arrived from a co-editing peer.
    public var onRemoteDelta: ((WorldDelta) -> Void)?

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
    private var machine: EventMachine
    private var localProfile: AvatarProfile
    private var tickTimer: DispatchSourceTimer?
    private let startedAt = Date()

    // MARK: Init

    public init(world: WorldDocument, configuration: Configuration, localPeerID: PeerID, localProfile: AvatarProfile) {
        self.configuration = configuration
        self.localPeerID = localPeerID
        self.localProfile = localProfile
        self.codec = PacketCodec(localPeerID: localPeerID)
        self.machine = EventMachine(world: world, startTime: 0)

        // The host is a player too.
        machine.addPlayer(PlayerSnapshot(peerID: localPeerID, profile: localProfile))
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        state = .starting
        do {
            let parameters = TLSPeerSecurity.parameters(roomCode: configuration.roomCode)
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
        queue.async { [weak self] in
            guard let self else { return }
            self.tickTimer?.cancel()
            self.tickTimer = nil
            for connection in self.connections.values {
                connection.sendEmpty(.leave)
                connection.cancel()
            }
            self.connections.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.state = .idle
        }
    }

    /// Bonjour TXT record, so the lobby can show world name and player count
    /// without anyone having to connect first.
    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[AbloxProtocol.TXTKey.worldName] = configuration.worldName
        txt[AbloxProtocol.TXTKey.hostName] = configuration.hostName
        txt[AbloxProtocol.TXTKey.players] = String(machine.players.count)
        txt[AbloxProtocol.TXTKey.capacity] = String(configuration.capacity)
        txt[AbloxProtocol.TXTKey.mode] = configuration.isStudioSession ? "studio" : "play"
        txt[AbloxProtocol.TXTKey.protocolVersion] = String(AbloxProtocol.version)
        return txt
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
        guard machine.players.count < configuration.capacity else {
            // Full. Closing immediately is clearer than letting the handshake
            // hang; the joining player sees "that world is full".
            nwConnection.cancel()
            return
        }

        let peer = PeerConnection(adopting: nwConnection, codec: codec, queue: queue)
        let key = ObjectIdentifier(peer)
        connections[key] = peer

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
        connections.removeValue(forKey: ObjectIdentifier(peer))
        guard let peerID = peer.remotePeerID else { return }
        machine.removePlayer(peerID)
        broadcast(.leave, LeavePayload(peerID: peerID))
        publishRoster()
        refreshAdvertisement()
    }

    // MARK: Packet handling

    private func handle(_ packet: Packet, from peer: PeerConnection) {
        switch packet.kind {
        case .handshake:
            handleHandshake(packet, from: peer)

        case .playerTransform:
            guard let payload = try? codec.decodePayload(PlayerTransformPayload.self, from: packet) else { return }
            // A client may only move its own avatar. Without this check any
            // peer could shove everyone else around the world.
            guard payload.peerID == peer.remotePeerID else { return }
            machine.updateTransform(payload)
            relay(packet, excluding: peer)

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
            dispatch(machine.handle(observation))

        case .worldDelta:
            guard let delta = try? codec.decodePayload(WorldDelta.self, from: packet) else { return }
            guard configuration.isStudioSession else { return }
            machine.apply(delta)
            relay(packet, excluding: peer)
            onRemoteDelta?(delta)

        case .chat:
            guard let payload = try? codec.decodePayload(ChatPayload.self, from: packet) else { return }
            relay(packet, excluding: peer)
            onChat?(payload)

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

        machine.addPlayer(PlayerSnapshot(peerID: payload.peerID, profile: payload.profile))

        // Reply with our own details, then the world, then the roster —
        // in that order, so the client can render the world before it has to
        // place anyone in it.
        peer.send(.handshake, HandshakePayload(
            peerID: localPeerID,
            profile: localProfile,
            worldName: configuration.worldName,
            isHost: true,
            capacity: configuration.capacity
        ))
        peer.send(.worldSnapshot, machine.world)
        publishRoster()
        refreshAdvertisement()
    }

    // MARK: Broadcasting

    private func relay(_ packet: Packet, excluding sender: PeerConnection?) {
        for connection in connections.values where connection !== sender {
            connection.send(packet)
        }
    }

    private func broadcast<T: Encodable>(_ kind: PacketKind, _ payload: T) {
        guard let packet = try? codec.encode(kind, payload) else { return }
        relay(packet, excluding: nil)
    }

    private func publishRoster() {
        let roster = machine.roster
        broadcast(.roster, RosterPayload(players: roster))
        onRosterChange?(roster)
    }

    /// Routes resolved effects: shared ones to everyone, personal ones only to
    /// the player they concern.
    private func dispatch(_ effects: [EventMachine.Effect]) {
        guard !effects.isEmpty else { return }
        let (broadcastPayload, targeted) = effects.groupedIntoPayloads()

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
            self.machine.updateTransform(PlayerTransformPayload(snapshot: snapshot))
            self.broadcast(.playerTransform, PlayerTransformPayload(snapshot: snapshot))
        }
    }

    public func reportLocalObservation(_ observation: EventMachine.Observation) {
        queue.async { [weak self] in
            guard let self, !self.configuration.isStudioSession else { return }
            self.dispatch(self.machine.handle(observation))
        }
    }

    public func sendChat(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let payload = ChatPayload(senderName: self.localProfile.displayName, text: text)
            self.broadcast(.chat, payload)
            self.onChat?(payload)
        }
    }

    /// Pushes a Studio edit to co-editing peers.
    public func publish(delta: WorldDelta) {
        queue.async { [weak self] in
            guard let self else { return }
            self.machine.apply(delta)
            self.broadcast(.worldDelta, delta)
        }
    }

    public func startRound() {
        queue.async { [weak self] in
            guard let self else { return }
            self.dispatch(self.machine.handle(.roundStarted))
        }
    }

    public func updateLocalProfile(_ profile: AvatarProfile) {
        queue.async { [weak self] in
            guard let self else { return }
            self.localProfile = profile
            self.machine.addPlayer(PlayerSnapshot(peerID: self.localPeerID, profile: profile))
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
            let elapsed = Date().timeIntervalSince(self.startedAt)
            self.dispatch(self.machine.advance(to: elapsed))
        }
        timer.resume()
        tickTimer = timer
    }

    // MARK: Introspection

    public var roomCode: String { configuration.roomCode }

    public var connectedCount: Int {
        connections.count
    }
}
