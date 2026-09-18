import Foundation

// MARK: - PeerID

/// Stable identity for one device in a session.
///
/// A thin wrapper over `UUID` rather than a bare `UUID` so that a peer id can
/// never be silently confused with a block id — both are UUIDs, and they show
/// up side by side in packet payloads.
public struct PeerID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    /// The 16 raw bytes, as they appear in a packet header.
    public var bytes: [UInt8] {
        let u = raw.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// Rebuilds a peer id from exactly 16 bytes. Returns nil otherwise.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16 else { return nil }
        raw = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public var description: String { String(raw.uuidString.prefix(8)) }

    /// FNV-1a over all sixteen id bytes, salted with `seed`.
    ///
    /// Stable across processes, platforms and launches — unlike `hashValue`,
    /// which Swift seeds randomly per process. Used wherever a peer id needs
    /// to pick deterministically from a list (avatar looks, colour slots) and
    /// every device must reach the same answer.
    public func stableHash(seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 &+ seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Sentinel used by the host when a message is server-authored rather
    /// than relayed from a player.
    public static let host = PeerID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
}

// MARK: - AvatarProfile

/// How a player looks and what they are called. Small enough to ride along in
/// the handshake, so joining players appear correctly on the first frame.
public struct AvatarProfile: Codable, Hashable, Sendable {
    public var displayName: String
    public var bodyColor: ColorRGBA
    public var headColor: ColorRGBA
    public var accentColor: ColorRGBA
    public var hat: HatStyle
    public var height: Float

    public init(
        displayName: String = "Player",
        bodyColor: ColorRGBA = ColorRGBA(hex: "#22D3EE")!,
        headColor: ColorRGBA = ColorRGBA(hex: "#FFD60A")!,
        accentColor: ColorRGBA = ColorRGBA(hex: "#A855F7")!,
        hat: HatStyle = .none,
        height: Float = 1.0
    ) {
        self.displayName = displayName
        self.bodyColor = bodyColor
        self.headColor = headColor
        self.accentColor = accentColor
        self.hat = hat
        self.height = height
    }

    public enum HatStyle: String, Codable, CaseIterable, Sendable {
        case none, cap, crown, antenna, halo

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .cap: return "Cap"
            case .crown: return "Crown"
            case .antenna: return "Antenna"
            case .halo: return "Halo"
            }
        }

        public var symbolName: String {
            switch self {
            case .none: return "nosign"
            case .cap: return "cap.fill"
            case .crown: return "crown.fill"
            case .antenna: return "antenna.radiowaves.left.and.right"
            case .halo: return "circle.circle"
            }
        }
    }

    public static let `default` = AvatarProfile()

    /// A deterministic, distinguishable look derived from a peer id, used for
    /// players who never opened the avatar editor.
    ///
    /// Every attribute is derived from a hash of **all sixteen** id bytes
    /// under a different seed. Indexing individual bytes instead would give
    /// identical avatars to any two peers whose ids share a prefix, which is
    /// exactly what happens when ids are minted somewhere other than
    /// `UUID()` — a test peer, a replay fixture, a future deterministic id.
    ///
    /// `Hasher` is deliberately not used: it is randomly seeded per process,
    /// so the same peer would look different on every iPad.
    public static func generated(for peer: PeerID, name: String) -> AvatarProfile {
        let palette = ColorRGBA.palette
        let hats = HatStyle.allCases
        return AvatarProfile(
            displayName: name,
            bodyColor: palette[Int(peer.stableHash(seed: 0x9E37) % UInt64(palette.count))],
            headColor: palette[Int(peer.stableHash(seed: 0x85EB) % UInt64(palette.count))],
            accentColor: palette[Int(peer.stableHash(seed: 0xC2B2) % UInt64(palette.count))],
            hat: hats[Int(peer.stableHash(seed: 0x27D4) % UInt64(hats.count))],
            height: 0.9 + Float(peer.stableHash(seed: 0x1656) % 20) / 100
        )
    }
}

// MARK: - PlayerSnapshot

/// One player's authoritative-ish state, as replicated over the wire.
///
/// Ablox uses host-relayed peer authority: each client owns its own avatar's
/// transform and the host forwards it. That keeps latency low on a local mesh
/// and avoids writing prediction/reconciliation, at the cost of trusting
/// peers — acceptable for a friends-in-the-same-room product, and noted in
/// `docs/networking.md`.
public struct PlayerSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var peerID: PeerID
    public var profile: AvatarProfile
    public var position: Vec3
    public var yawDegrees: Float
    public var velocity: Vec3
    public var isGrounded: Bool
    public var score: Int
    public var isReady: Bool

    public var id: PeerID { peerID }

    public init(
        peerID: PeerID,
        profile: AvatarProfile = .default,
        position: Vec3 = .zero,
        yawDegrees: Float = 0,
        velocity: Vec3 = .zero,
        isGrounded: Bool = true,
        score: Int = 0,
        isReady: Bool = false
    ) {
        self.peerID = peerID
        self.profile = profile
        self.position = position
        self.yawDegrees = yawDegrees
        self.velocity = velocity
        self.isGrounded = isGrounded
        self.score = score
        self.isReady = isReady
    }
}

// MARK: - Interpolation

public extension PlayerSnapshot {
    /// Blends toward `target` for smoothing remote avatars between the ~15 Hz
    /// transform packets. Yaw uses shortest-arc so an avatar crossing 180°
    /// does not spin the long way.
    func interpolated(toward target: PlayerSnapshot, t: Float) -> PlayerSnapshot {
        var result = target
        result.position = Vec3.lerp(position, target.position, t)
        result.yawDegrees = normalizeDegrees(yawDegrees + angularDelta(from: yawDegrees, to: target.yawDegrees) * t)
        result.velocity = Vec3.lerp(velocity, target.velocity, t)
        return result
    }
}

// MARK: - Movement

/// Player movement tuning. Exposed as data so Settings can offer a "floaty /
/// snappy" slider without touching the controller.
public struct MovementConfig: Codable, Hashable, Sendable {
    public var walkSpeed: Float
    public var runMultiplier: Float
    public var jumpSpeed: Float
    public var gravity: Float
    public var airControl: Float
    /// Metres per second of horizontal damping applied when the stick is idle.
    public var groundFriction: Float
    public var maxFallSpeed: Float
    public var turnSpeedDegreesPerSecond: Float

    public init(
        walkSpeed: Float = 5.0,
        runMultiplier: Float = 1.8,
        jumpSpeed: Float = 6.0,
        gravity: Float = -18.0,
        airControl: Float = 0.45,
        groundFriction: Float = 12.0,
        maxFallSpeed: Float = -45.0,
        turnSpeedDegreesPerSecond: Float = 540
    ) {
        self.walkSpeed = walkSpeed
        self.runMultiplier = runMultiplier
        self.jumpSpeed = jumpSpeed
        self.gravity = gravity
        self.airControl = airControl
        self.groundFriction = groundFriction
        self.maxFallSpeed = maxFallSpeed
        self.turnSpeedDegreesPerSecond = turnSpeedDegreesPerSecond
    }

    public static let `default` = MovementConfig()
}

/// Per-frame player intent, produced by the on-screen joystick (or, in the
/// Studio's preview, by a keyboard).
public struct MovementInput: Hashable, Sendable {
    /// Stick offset in `-1...1` on each axis. `y` is forward.
    public var stick: Vec3
    public var isJumping: Bool
    public var isRunning: Bool
    /// Camera yaw, so "forward" means "away from the camera".
    public var cameraYawDegrees: Float

    public init(stick: Vec3 = .zero, isJumping: Bool = false, isRunning: Bool = false, cameraYawDegrees: Float = 0) {
        self.stick = stick
        self.isJumping = isJumping
        self.isRunning = isRunning
        self.cameraYawDegrees = cameraYawDegrees
    }

    public static let idle = MovementInput()

    /// Stick magnitude, clamped to 1 so diagonals are not faster.
    public var magnitude: Float {
        Swift.min(1, Vec3(stick.x, 0, stick.z).length)
    }
}

/// Character motion, solved in plain Swift so it is unit-testable and
/// identical on host and client. RealityKit applies the result; it does not
/// decide it.
public enum CharacterSolver {
    /// Advances horizontal velocity and applies gravity for one step.
    ///
    /// - Parameters:
    ///   - snapshot: current player state.
    ///   - input: this frame's intent.
    ///   - config: tuning.
    ///   - deltaTime: seconds since the last step, clamped by the caller.
    /// - Returns: the new velocity and facing, with position left to the
    ///   collision pass that owns it.
    public static func step(
        snapshot: PlayerSnapshot,
        input: MovementInput,
        config: MovementConfig = .default,
        deltaTime: Float
    ) -> (velocity: Vec3, yawDegrees: Float) {
        let dt = Swift.max(0, Swift.min(deltaTime, 0.1))

        // Rotate the stick into world space around the camera.
        let cameraYaw = Quat.yaw(degrees: input.cameraYawDegrees)
        let desiredDirection = cameraYaw.act(Vec3(input.stick.x, 0, -input.stick.z)).normalized
        let magnitude = input.magnitude

        let targetSpeed = config.walkSpeed * (input.isRunning ? config.runMultiplier : 1) * magnitude
        let targetVelocity = desiredDirection * targetSpeed

        var horizontal = Vec3(snapshot.velocity.x, 0, snapshot.velocity.z)
        if snapshot.isGrounded {
            if magnitude > 0.01 {
                horizontal = targetVelocity
            } else {
                // Decay toward a stop rather than snapping, so letting go of
                // the stick still feels weighty.
                let decay = Swift.max(0, 1 - config.groundFriction * dt)
                horizontal = horizontal * decay
            }
        } else {
            // In the air the player only nudges their trajectory.
            horizontal = Vec3.lerp(horizontal, targetVelocity, Swift.min(1, config.airControl * dt * 6))
        }

        var verticalSpeed = snapshot.velocity.y
        if input.isJumping && snapshot.isGrounded {
            verticalSpeed = config.jumpSpeed
        } else {
            verticalSpeed = Swift.max(config.maxFallSpeed, verticalSpeed + config.gravity * dt)
        }

        // Face the way we are moving; keep the old facing when standing still.
        var yaw = snapshot.yawDegrees
        if magnitude > 0.01 {
            let targetYaw = atan2(desiredDirection.x, -desiredDirection.z) * 180 / .pi
            let delta = angularDelta(from: yaw, to: targetYaw)
            let maxStep = config.turnSpeedDegreesPerSecond * dt
            yaw = normalizeDegrees(yaw + Swift.max(-maxStep, Swift.min(maxStep, delta)))
        }

        return (Vec3(horizontal.x, verticalSpeed, horizontal.z), yaw)
    }
}
