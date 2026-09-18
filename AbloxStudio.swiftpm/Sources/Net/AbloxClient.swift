import Foundation
import Network

/// The joining side of a session: one TLS connection to a host, plus the
/// replicated world and roster it sends back.
public final class AbloxClient {

    public enum State: Equatable {
        case idle
        case connecting
        /// Connected, but the world has not arrived yet.
        case handshaking
        case playing
        case disconnected(String)
    }

    public var onStateChange: ((State) -> Void)?
    public var onWorld: ((WorldDocument) -> Void)?
    public var onDelta: ((WorldDelta) -> Void)?
    public var onRoster: (([PlayerSnapshot]) -> Void)?
    public var onTransform: ((PlayerTransformPayload) -> Void)?
    public var onEffects: ((EventEffectPayload) -> Void)?
    public var onChat: ((ChatPayload) -> Void)?

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    public let localPeerID: PeerID
    public private(set) var hostPeerID: PeerID?
    public private(set) var worldName: String = ""

    /// Round-trip time to the host, in milliseconds.
    public var pingMilliseconds: Double? { connection?.roundTripMilliseconds }

    private let codec: PacketCodec
    private let queue = DispatchQueue(label: "com.ablox.client", qos: .userInitiated)
    private var connection: PeerConnection?
    private var profile: AvatarProfile
    private var pingTimer: DispatchSourceTimer?

    public init(localPeerID: PeerID, profile: AvatarProfile) {
        self.localPeerID = localPeerID
        self.profile = profile
        self.codec = PacketCodec(localPeerID: localPeerID)
    }

    // MARK: Lifecycle

    public func connect(to peer: DiscoveredPeer, roomCode: String) {
        connect(to: peer.endpoint, roomCode: roomCode)
    }

    public func connect(to endpoint: NWEndpoint, roomCode: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectOnQueue(reason: nil)
            self.state = .connecting

            let connection = PeerConnection(endpoint: endpoint, roomCode: roomCode, codec: self.codec, queue: self.queue)

            connection.onStateChange = { [weak self] connectionState in
                guard let self else { return }
                switch connectionState {
                case .ready:
                    self.state = .handshaking
                    // Introduce ourselves; the host replies with the world.
                    connection.send(.handshake, HandshakePayload(peerID: self.localPeerID, profile: self.profile))
                    self.startPinging()
                case let .failed(reason):
                    self.state = .disconnected(reason)
                    self.stopPinging()
                case .cancelled:
                    if case .disconnected = self.state {} else {
                        self.state = .disconnected("Disconnected from the host.")
                    }
                    self.stopPinging()
                case .setup, .connecting:
                    break
                }
            }

            connection.onPacket = { [weak self] packet in
                self?.handle(packet)
            }

            self.connection = connection
            connection.start()
        }
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.disconnectOnQueue(reason: "You left the world.")
        }
    }

    private func disconnectOnQueue(reason: String?) {
        stopPinging()
        if let connection {
            connection.sendEmpty(.leave)
            connection.cancel()
        }
        connection = nil
        if let reason {
            state = .disconnected(reason)
        }
    }

    // MARK: Packets

    private func handle(_ packet: Packet) {
        switch packet.kind {
        case .handshake:
            guard let payload = try? codec.decodePayload(HandshakePayload.self, from: packet) else { return }
            hostPeerID = payload.peerID
            worldName = payload.worldName

        case .worldSnapshot:
            guard let world = try? codec.decodePayload(WorldDocument.self, from: packet) else { return }
            state = .playing
            onWorld?(world)

        case .worldDelta:
            guard let delta = try? codec.decodePayload(WorldDelta.self, from: packet) else { return }
            onDelta?(delta)

        case .roster:
            guard let payload = try? codec.decodePayload(RosterPayload.self, from: packet) else { return }
            onRoster?(payload.players)

        case .playerTransform:
            guard let payload = try? codec.decodePayload(PlayerTransformPayload.self, from: packet) else { return }
            // Our own transform coming back from the relay would fight the
            // local simulation, so ignore the echo.
            guard payload.peerID != localPeerID else { return }
            onTransform?(payload)

        case .eventEffect:
            guard let payload = try? codec.decodePayload(EventEffectPayload.self, from: packet) else { return }
            // Targeted effects for somebody else are none of our business, but
            // the host only sends those on that peer's own connection — so
            // anything arriving here is either broadcast or ours.
            onEffects?(payload)

        case .chat:
            guard let payload = try? codec.decodePayload(ChatPayload.self, from: packet) else { return }
            onChat?(payload)

        case .leave:
            if let payload = try? codec.decodePayload(LeavePayload.self, from: packet), payload.peerID == hostPeerID {
                state = .disconnected("The host closed the world.")
            }

        case .eventTrigger, .ping, .pong:
            break
        }
    }

    // MARK: Sending

    public func publishLocalTransform(_ snapshot: PlayerSnapshot) {
        queue.async { [weak self] in
            guard let self, self.state == .playing else { return }
            self.connection?.send(.playerTransform, PlayerTransformPayload(snapshot: snapshot))
        }
    }

    public func report(blockID: UUID, cause: EventTriggerPayload.Cause) {
        queue.async { [weak self] in
            guard let self, self.state == .playing else { return }
            self.connection?.send(.eventTrigger, EventTriggerPayload(peerID: self.localPeerID, blockID: blockID, cause: cause))
        }
    }

    public func sendChat(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.send(.chat, ChatPayload(senderName: self.profile.displayName, text: text))
        }
    }

    /// Studio co-editing: push a local edit to the host, which relays it.
    public func publish(delta: WorldDelta) {
        queue.async { [weak self] in
            self?.connection?.send(.worldDelta, delta)
        }
    }

    public func updateProfile(_ profile: AvatarProfile) {
        queue.async { [weak self] in
            guard let self else { return }
            self.profile = profile
            self.connection?.send(.handshake, HandshakePayload(peerID: self.localPeerID, profile: profile))
        }
    }

    // MARK: Ping

    private func startPinging() {
        stopPinging()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.connection?.ping()
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPinging() {
        pingTimer?.cancel()
        pingTimer = nil
    }
}
