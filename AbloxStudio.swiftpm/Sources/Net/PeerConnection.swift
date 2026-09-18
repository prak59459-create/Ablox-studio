import Foundation
import Network
import AbloxCore

/// One TLS connection to another iPad, in either direction.
///
/// Wraps `NWConnection` so the rest of the app deals in typed packets rather
/// than bytes and state enums. All `NWConnection` work happens on a private
/// serial queue; callbacks are delivered on that same queue, and the callers
/// that touch UI hop to the main actor themselves.
public final class PeerConnection {

    public enum State: Equatable {
        case setup
        case connecting
        /// TLS handshake finished and the Ablox handshake has been exchanged.
        case ready
        case failed(String)
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .failed, .cancelled: return true
            case .setup, .connecting, .ready: return false
            }
        }
    }

    /// Identity of the peer on the other end, learned from its handshake.
    public private(set) var remotePeerID: PeerID?
    public private(set) var remoteProfile: AvatarProfile?

    public private(set) var state: State = .setup {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Most recent round-trip time, from the ping/pong pair.
    public private(set) var roundTripMilliseconds: Double?

    public var onStateChange: ((State) -> Void)?
    public var onPacket: ((Packet) -> Void)?

    public let connection: NWConnection
    private let queue: DispatchQueue
    private let codec: PacketCodec

    /// Last sequence seen per packet kind, so a late `playerTransform` cannot
    /// rubber-band an avatar backwards.
    private var lastSequenceByKind: [PacketKind: UInt32] = [:]

    private var pendingPings: [UInt32: UInt64] = [:]
    private var pingNonce: UInt32 = 0

    // MARK: Init

    /// Outbound: we are joining someone else's session.
    public init(endpoint: NWEndpoint, roomCode: String, codec: PacketCodec, queue: DispatchQueue) {
        self.codec = codec
        self.queue = queue
        self.connection = NWConnection(to: endpoint, using: TLSPeerSecurity.parameters(roomCode: roomCode))
    }

    /// Inbound: the listener handed us a connection someone made to us.
    public init(adopting connection: NWConnection, codec: PacketCodec, queue: DispatchQueue) {
        self.codec = codec
        self.queue = queue
        self.connection = connection
    }

    // MARK: Lifecycle

    public func start() {
        state = .connecting
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                self.state = .ready
                self.receiveNext()
            case let .failed(error):
                self.state = .failed(Self.describe(error))
            case let .waiting(error):
                // `waiting` on a local mesh usually means the peer is not
                // reachable yet. Surface it rather than spinning silently —
                // Network.framework will keep retrying underneath.
                self.state = .failed(Self.describe(error))
            case .cancelled:
                self.state = .cancelled
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    /// Human-readable reason, with the PSK mismatch called out specifically —
    /// "-9836" tells a 12-year-old nothing, "wrong room code" tells them
    /// everything.
    static func describe(_ error: NWError) -> String {
        if case let .tls(status) = error {
            // errSSLBadRecordMac / handshake failures are what a wrong PSK
            // looks like from the outside.
            switch status {
            case -9800...(-9800 + 200):
                return "Could not connect — check the room code is the same on both iPads."
            default:
                return "Secure connection failed (TLS \(status))."
            }
        }
        if case let .posix(code) = error {
            switch code {
            case .ECONNREFUSED: return "That iPad is no longer hosting."
            case .ETIMEDOUT: return "The other iPad stopped responding."
            case .ENETDOWN, .ENETUNREACH: return "No network. Check Wi-Fi is on."
            case .ECANCELED: return "Connection cancelled."
            default: return "Network error (\(code))."
            }
        }
        return error.localizedDescription
    }

    // MARK: Sending

    /// Sends a typed payload. Errors are reported through `onStateChange`
    /// rather than thrown, because every caller is a fire-and-forget game
    /// event with nothing useful to do about a failure.
    public func send<T: Encodable>(_ kind: PacketKind, _ payload: T, sender: PeerID? = nil) {
        do {
            let packet = try codec.encode(kind, payload, sender: sender)
            send(packet)
        } catch {
            state = .failed("Could not encode \(kind): \(error.localizedDescription)")
        }
    }

    public func send(_ packet: Packet) {
        let message = NWProtocolFramer.Message(abloxHeader: packet.header)
        let context = NWConnection.ContentContext(identifier: "ablox", metadata: [message])

        connection.send(
            content: packet.payload,
            contentContext: context,
            isComplete: true,
            // High-frequency transforms are idempotent: the next one supersedes
            // this one, so there is nothing to gain from queueing them behind a
            // completion handler.
            completion: packet.kind.isHighFrequency ? .idempotent : .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.state = .failed(PeerConnection.describe(error))
            }
        )
    }

    public func sendEmpty(_ kind: PacketKind) {
        send(codec.encodeEmpty(kind))
    }

    // MARK: Receiving

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            if let error {
                self.state = .failed(PeerConnection.describe(error))
                return
            }

            if let message = context?.protocolMetadata(definition: AbloxFramer.definition) as? NWProtocolFramer.Message,
               let header = message.abloxHeader {
                self.deliver(Packet(header: header, payload: content ?? Data()))
            }

            // `isComplete` with no content is the peer closing cleanly.
            if isComplete, content == nil, context?.isFinal == true {
                self.state = .cancelled
                return
            }

            guard !self.state.isTerminal else { return }
            self.receiveNext()
        }
    }

    private func deliver(_ packet: Packet) {
        // Drop stale high-frequency packets. Reliable kinds (world edits,
        // chat, handshakes) are always delivered: losing one would desync the
        // world permanently, whereas a late transform is simply irrelevant.
        if packet.kind.isHighFrequency, let last = lastSequenceByKind[packet.kind] {
            guard isSequence(packet.header.sequence, newerThan: last) else { return }
        }
        lastSequenceByKind[packet.kind] = packet.header.sequence

        switch packet.kind {
        case .handshake:
            if let payload = try? codec.decodePayload(HandshakePayload.self, from: packet) {
                remotePeerID = payload.peerID
                remoteProfile = payload.profile
            }
        case .ping:
            // Reply immediately, at the transport layer, so the measured RTT
            // reflects the network rather than how busy the render loop is.
            if let payload = try? codec.decodePayload(PingPayload.self, from: packet) {
                send(.pong, payload)
            }
        case .pong:
            if let payload = try? codec.decodePayload(PingPayload.self, from: packet),
               let sentAt = pendingPings.removeValue(forKey: payload.nonce) {
                roundTripMilliseconds = Double(PacketCodec.nowMilliseconds() - sentAt)
            }
        default:
            break
        }

        onPacket?(packet)
    }

    // MARK: Ping

    public func ping() {
        pingNonce &+= 1
        let now = PacketCodec.nowMilliseconds()
        pendingPings[pingNonce] = now
        // Bound the outstanding set: a peer that never answers must not grow
        // this dictionary without limit.
        if pendingPings.count > 16 {
            let stale = pendingPings.filter { now - $0.value > 10_000 }.map(\.key)
            for key in stale { pendingPings.removeValue(forKey: key) }
        }
        send(.ping, PingPayload(nonce: pingNonce, sentAtMilliseconds: now))
    }
}
