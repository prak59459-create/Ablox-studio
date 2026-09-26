import Foundation

// MARK: - PacketKind

/// The message vocabulary of the Ablox mesh.
///
/// Raw values are frozen: they travel on the wire, so reordering the cases
/// would break compatibility with an iPad running an older build.
public enum PacketKind: UInt8, Codable, CaseIterable, Sendable {
    /// Client → host on connect, host → client in reply.
    case handshake = 1
    /// Host → client. The complete world, sent once after the handshake.
    case worldSnapshot = 2
    /// Host ↔ client. An incremental world edit (live co-editing in Studio).
    case worldDelta = 3
    /// Client → host → everyone. An avatar's position and facing.
    case playerTransform = 4
    /// Host → client. The full player roster, on join and leave.
    case roster = 5
    /// Client → host. "I touched / tapped this block."
    case eventTrigger = 6
    /// Host → client. "This rule fired; run these effects."
    case eventEffect = 7
    /// Any → any. Text chat.
    case chat = 8
    /// Round-trip timing.
    case ping = 9
    case pong = 10
    /// Sent on a clean disconnect so peers disappear immediately rather than
    /// waiting for a socket timeout.
    case leave = 11
    /// Client → host. A button press a script cares about: firing a weapon,
    /// tapping a button on the script's screen GUI.
    case playerInput = 12

    public var isHighFrequency: Bool {
        self == .playerTransform
    }
}

// MARK: - PacketHeader

/// The fixed-size prefix on every framed message.
///
/// Binary rather than JSON because `playerTransform` goes out ~15 times a
/// second per player; a 33-byte header plus a compact JSON body beats
/// base64-ing a payload inside an outer JSON envelope.
///
/// Layout, all integers big-endian (network order):
/// ```
///  offset  size  field
///       0     1  kind
///       1    16  senderID (raw UUID bytes)
///      17     4  sequence
///      21     8  timestampMilliseconds
///      29     4  payloadLength
/// ```
public struct PacketHeader: Hashable, Sendable {
    public static let encodedSize = 33

    public var kind: PacketKind
    public var senderID: PeerID
    public var sequence: UInt32
    public var timestampMilliseconds: UInt64
    public var payloadLength: UInt32

    public init(
        kind: PacketKind,
        senderID: PeerID,
        sequence: UInt32,
        timestampMilliseconds: UInt64,
        payloadLength: UInt32
    ) {
        self.kind = kind
        self.senderID = senderID
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.payloadLength = payloadLength
    }

    public var timestamp: Date {
        Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1000)
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.encodedSize)
        data.append(kind.rawValue)
        data.append(contentsOf: senderID.bytes)
        data.append(contentsOf: bigEndianBytes(of: sequence))
        data.append(contentsOf: bigEndianBytes(of: timestampMilliseconds))
        data.append(contentsOf: bigEndianBytes(of: payloadLength))
        return data
    }

    /// Parses a header from the first `encodedSize` bytes of `data`.
    /// Returns nil when the buffer is short or the kind byte is unknown —
    /// both are "wait for more" / "drop the connection" signals, not crashes.
    public init?(decoding data: Data) {
        guard data.count >= Self.encodedSize else { return nil }
        let bytes = [UInt8](data.prefix(Self.encodedSize))

        guard let kind = PacketKind(rawValue: bytes[0]) else { return nil }
        guard let sender = PeerID(bytes: Array(bytes[1..<17])) else { return nil }

        self.kind = kind
        self.senderID = sender
        self.sequence = bigEndianValue(bytes[17..<21])
        self.timestampMilliseconds = bigEndianValue(bytes[21..<29])
        self.payloadLength = bigEndianValue(bytes[29..<33])
    }
}

// MARK: - Byte helpers

@inline(__always)
func bigEndianBytes<T: FixedWidthInteger>(of value: T) -> [UInt8] {
    let big = value.bigEndian
    return withUnsafeBytes(of: big) { Array($0) }
}

@inline(__always)
func bigEndianValue<T: FixedWidthInteger>(_ slice: ArraySlice<UInt8>) -> T {
    var result: T = 0
    for byte in slice {
        result = (result << 8) | T(byte)
    }
    return result
}

// MARK: - Payloads

/// Sent by a joining client, and echoed back by the host with its own details.
public struct HandshakePayload: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var peerID: PeerID
    public var profile: AvatarProfile
    public var worldName: String
    public var isHost: Bool
    /// Host → client only: the session's max player count.
    public var capacity: Int

    public init(
        protocolVersion: Int = AbloxProtocol.version,
        peerID: PeerID,
        profile: AvatarProfile,
        worldName: String = "",
        isHost: Bool = false,
        capacity: Int = 8
    ) {
        self.protocolVersion = protocolVersion
        self.peerID = peerID
        self.profile = profile
        self.worldName = worldName
        self.isHost = isHost
        self.capacity = capacity
    }
}

/// An incremental world edit. Studio broadcasts these while co-editing so a
/// second iPad sees blocks appear as they are dragged, without resending the
/// entire document on every frame.
public enum WorldDelta: Codable, Hashable, Sendable {
    case insert(BlockData)
    case update(BlockData)
    case remove(blockID: UUID)
    case reparent(blockID: UUID, newParent: UUID?)
    case environment(EnvironmentSettings)
    case rulesReplaced([EventRule])
    case scriptsReplaced([ScriptFile])
    case scriptSourceChanged(ScriptSource?)

    private enum CodingKeys: String, CodingKey {
        case type, block, blockID, newParent, environment, rules, scripts, scriptSource
    }

    private enum Kind: String, Codable {
        case insert, update, remove, reparent, environment, rulesReplaced, scriptsReplaced, scriptSourceChanged
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .insert(block):
            try c.encode(Kind.insert, forKey: .type)
            try c.encode(block, forKey: .block)
        case let .update(block):
            try c.encode(Kind.update, forKey: .type)
            try c.encode(block, forKey: .block)
        case let .remove(blockID):
            try c.encode(Kind.remove, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
        case let .reparent(blockID, newParent):
            try c.encode(Kind.reparent, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
            try c.encodeIfPresent(newParent, forKey: .newParent)
        case let .environment(settings):
            try c.encode(Kind.environment, forKey: .type)
            try c.encode(settings, forKey: .environment)
        case let .rulesReplaced(rules):
            try c.encode(Kind.rulesReplaced, forKey: .type)
            try c.encode(rules, forKey: .rules)
        case let .scriptsReplaced(scripts):
            try c.encode(Kind.scriptsReplaced, forKey: .type)
            try c.encode(scripts, forKey: .scripts)
        case let .scriptSourceChanged(source):
            try c.encode(Kind.scriptSourceChanged, forKey: .type)
            try c.encodeIfPresent(source, forKey: .scriptSource)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .insert: self = .insert(try c.decode(BlockData.self, forKey: .block))
        case .update: self = .update(try c.decode(BlockData.self, forKey: .block))
        case .remove: self = .remove(blockID: try c.decode(UUID.self, forKey: .blockID))
        case .reparent:
            self = .reparent(
                blockID: try c.decode(UUID.self, forKey: .blockID),
                newParent: try c.decodeIfPresent(UUID.self, forKey: .newParent)
            )
        case .environment: self = .environment(try c.decode(EnvironmentSettings.self, forKey: .environment))
        case .rulesReplaced: self = .rulesReplaced(try c.decode([EventRule].self, forKey: .rules))
        case .scriptsReplaced: self = .scriptsReplaced(try c.decode([ScriptFile].self, forKey: .scripts))
        case .scriptSourceChanged: self = .scriptSourceChanged(try c.decodeIfPresent(ScriptSource.self, forKey: .scriptSource))
        }
    }

    /// Folds this delta into a world. Returns false when it could not be
    /// applied (usually because it raced a delete).
    @discardableResult
    public func apply(to world: inout WorldDocument) -> Bool {
        switch self {
        case let .insert(block):
            // Re-sending an insert must not duplicate the block: a client that
            // reconnects mid-edit can legitimately receive one twice.
            if world.index(of: block.id) != nil {
                return world.update(block)
            }
            world.insert(block)
            return true
        case let .update(block):
            return world.update(block)
        case let .remove(blockID):
            return !world.remove(id: blockID).isEmpty
        case let .reparent(blockID, newParent):
            return world.setParent(of: blockID, to: newParent)
        case let .environment(settings):
            world.environment = settings
            world.modifiedAt = Date()
            return true
        case let .rulesReplaced(rules):
            world.rules = rules
            world.modifiedAt = Date()
            return true
        case let .scriptsReplaced(scripts):
            world.scripts = scripts
            world.modifiedAt = Date()
            return true
        case let .scriptSourceChanged(source):
            world.scriptSource = source
            world.modifiedAt = Date()
            return true
        }
    }
}

/// A player's motion, sent at a fixed tick rate.
public struct PlayerTransformPayload: Codable, Hashable, Sendable {
    public var peerID: PeerID
    public var position: Vec3
    public var yawDegrees: Float
    public var velocity: Vec3
    public var isGrounded: Bool

    public init(peerID: PeerID, position: Vec3, yawDegrees: Float, velocity: Vec3 = .zero, isGrounded: Bool = true) {
        self.peerID = peerID
        self.position = position
        self.yawDegrees = yawDegrees
        self.velocity = velocity
        self.isGrounded = isGrounded
    }

    public init(snapshot: PlayerSnapshot) {
        self.init(
            peerID: snapshot.peerID,
            position: snapshot.position,
            yawDegrees: snapshot.yawDegrees,
            velocity: snapshot.velocity,
            isGrounded: snapshot.isGrounded
        )
    }
}

public struct RosterPayload: Codable, Hashable, Sendable {
    public var players: [PlayerSnapshot]

    public init(players: [PlayerSnapshot]) {
        self.players = players
    }
}

/// Client → host: "something happened to me". The host decides whether it
/// actually fires a rule; clients never self-report score changes.
public struct EventTriggerPayload: Codable, Hashable, Sendable {
    public enum Cause: String, Codable, Sendable {
        case touched
        case tapped
        case proximityEntered
    }

    public var peerID: PeerID
    public var blockID: UUID
    public var cause: Cause

    public init(peerID: PeerID, blockID: UUID, cause: Cause) {
        self.peerID = peerID
        self.blockID = blockID
        self.cause = cause
    }
}

/// Host → clients: the resolved consequences of a rule firing.
public struct EventEffectPayload: Codable, Hashable, Sendable {
    public var ruleID: UUID?
    /// The player the effects are scoped to, when they are personal
    /// (points, teleports). `nil` means everyone sees them.
    public var targetPeerID: PeerID?
    public var actions: [EventAction]

    public init(ruleID: UUID? = nil, targetPeerID: PeerID? = nil, actions: [EventAction]) {
        self.ruleID = ruleID
        self.targetPeerID = targetPeerID
        self.actions = actions
    }
}

/// Client → host: "I pressed something". Like `EventTriggerPayload`, a claim
/// the host checks rather than a result it accepts — a shot says where it
/// came from and which way it went, never what it hit.
public struct PlayerInputPayload: Codable, Hashable, Sendable {
    public enum Input: Codable, Hashable, Sendable {
        /// The fire button, aimed from `origin` along `direction`.
        case fire(origin: Vec3, direction: Vec3)
        /// A button a script put on the screen.
        case button(id: String)
        /// Reload before the magazine is empty.
        case reload
        /// Text typed into a script's input box and sent.
        case text(id: String, value: String)
        /// This player's saved data for the world being played, read from
        /// their iPad as they arrive. The host bounds it like any other claim.
        case saved(SaveData)
    }

    public var peerID: PeerID
    public var input: Input

    public init(peerID: PeerID, input: Input) {
        self.peerID = peerID
        self.input = input
    }
}

public struct ChatPayload: Codable, Hashable, Sendable {
    public var senderName: String
    public var text: String
    /// Who really said it, filled in by the host from the connection the
    /// message came in on. A guest's own claim — the name above, the packet
    /// header — is replaced, so no one can put words over someone else's head.
    public var senderID: PeerID?

    public init(senderName: String, text: String, senderID: PeerID? = nil) {
        self.senderName = senderName
        // Chat is rendered in a fixed-height overlay; clamp here so one peer
        // cannot paste a wall of text over everyone's viewport.
        self.text = String(text.prefix(AbloxProtocol.maxChatLength))
        self.senderID = senderID
    }
}

public struct PingPayload: Codable, Hashable, Sendable {
    /// Echoed verbatim in the pong so the sender can match the reply.
    public var nonce: UInt32
    public var sentAtMilliseconds: UInt64

    public init(nonce: UInt32, sentAtMilliseconds: UInt64) {
        self.nonce = nonce
        self.sentAtMilliseconds = sentAtMilliseconds
    }
}

public struct LeavePayload: Codable, Hashable, Sendable {
    public var peerID: PeerID
    public var reason: String

    public init(peerID: PeerID, reason: String = "") {
        self.peerID = peerID
        self.reason = reason
    }
}

// MARK: - Protocol constants

public enum AbloxProtocol {
    /// Bumped when the packet vocabulary changes incompatibly. A handshake
    /// with a different version is rejected with a readable message rather
    /// than left to fail mysteriously later.
    ///
    /// 2: `playerInput` and script effects (screen GUI, weapons, camera).
    /// 3: `.absc` script files, free-form GUI, NPCs and world editing.
    /// 4: an NPC's `say` is a speech bubble over its head (`ScriptEffect.say`).
    /// 5: saved game data (`PlayerInputPayload.Input.saved`, `ScriptEffect.store`).
    /// 6: the room key is stretched and salted (`TXTKey.salt`), and relayed
    ///    chat says who really sent it (`ChatPayload.senderID`). An older
    ///    iPad could not finish the TLS handshake, so the lobby must be able
    ///    to tell it why before it tries.
    public static let version = 6

    /// Bonjour service type advertised by hosts.
    public static let bonjourServiceType = "_ablox._tcp"

    /// TXT-record keys used to show world name and player count in the lobby
    /// list *before* connecting.
    public enum TXTKey {
        public static let worldName = "world"
        public static let hostName = "host"
        public static let players = "players"
        public static let capacity = "cap"
        public static let mode = "mode"
        public static let protocolVersion = "pv"
        /// "public" or "private". A host that predates the setting sends
        /// neither and is treated as private: its code was never shown.
        public static let access = "access"
        /// The room code, published only by a public room, so anyone nearby
        /// can join without typing it.
        public static let code = "code"
        /// Random per session, mixed into the key made from the room code so
        /// no table of precomputed keys works against it. Not a secret.
        public static let salt = "salt"
    }

    /// Hard ceiling on a single framed message. A `worldSnapshot` for a big
    /// world is the largest legitimate packet; anything past this is either a
    /// bug or a peer trying to exhaust our memory, so the connection is cut.
    public static let maxPayloadLength = 8 * 1024 * 1024

    public static let maxChatLength = 240

    /// Ceiling on how often avatars publish their transform. 20 Hz is smooth
    /// with client-side interpolation and leaves headroom on a crowded Wi-Fi.
    /// `TransformPublisher` sends well below this in practice — the rate only
    /// binds while an avatar is actually moving.
    public static let transformHz: Double = 20

    public static let defaultCapacity = 8

    /// Port 0 asks the OS for a free port; Bonjour carries the real one.
    public static let preferredPort: UInt16 = 0
}

// MARK: - Packet

/// A header plus its payload bytes — what the framer hands up and takes down.
public struct Packet: Hashable, Sendable {
    public var header: PacketHeader
    public var payload: Data

    public init(header: PacketHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }

    public var kind: PacketKind { header.kind }
    public var senderID: PeerID { header.senderID }
}
