import Foundation

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
    /// A character a script created and the host moves — not a person. Drawn
    /// like everyone else, left off the scoreboard.
    public var isNPC: Bool
    /// Hidden by a script: still in the game, not drawn.
    public var isHidden: Bool
    /// The team the host or the game put them on; empty for none.
    public var team: String

    public var id: PeerID { peerID }

    public init(
        peerID: PeerID,
        profile: AvatarProfile = .default,
        position: Vec3 = .zero,
        yawDegrees: Float = 0,
        velocity: Vec3 = .zero,
        isGrounded: Bool = true,
        score: Int = 0,
        isReady: Bool = false,
        isNPC: Bool = false,
        isHidden: Bool = false,
        team: String = ""
    ) {
        self.peerID = peerID
        self.profile = profile
        self.position = position
        self.yawDegrees = yawDegrees
        self.velocity = velocity
        self.isGrounded = isGrounded
        self.score = score
        self.isReady = isReady
        self.isNPC = isNPC
        self.isHidden = isHidden
        self.team = team
    }

    private enum CodingKeys: String, CodingKey {
        case peerID, profile, position, yawDegrees, velocity, isGrounded, score, isReady, isNPC, isHidden, team
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        peerID = try c.decode(PeerID.self, forKey: .peerID)
        profile = try c.decode(AvatarProfile.self, forKey: .profile)
        position = try c.decode(Vec3.self, forKey: .position)
        yawDegrees = try c.decode(Float.self, forKey: .yawDegrees)
        velocity = try c.decode(Vec3.self, forKey: .velocity)
        isGrounded = try c.decode(Bool.self, forKey: .isGrounded)
        score = try c.decode(Int.self, forKey: .score)
        isReady = try c.decode(Bool.self, forKey: .isReady)
        isNPC = try c.decodeIfPresent(Bool.self, forKey: .isNPC) ?? false
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        team = String((try c.decodeIfPresent(String.self, forKey: .team) ?? "").prefix(32))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(peerID, forKey: .peerID)
        try c.encode(profile, forKey: .profile)
        try c.encode(position, forKey: .position)
        try c.encode(yawDegrees, forKey: .yawDegrees)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(isGrounded, forKey: .isGrounded)
        try c.encode(score, forKey: .score)
        try c.encode(isReady, forKey: .isReady)
        try c.encode(isNPC, forKey: .isNPC)
        try c.encode(isHidden, forKey: .isHidden)
        if !team.isEmpty { try c.encode(team, forKey: .team) }
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

    // MARK: What a player can actually reach
    //
    // Derived from the numbers above rather than written down beside them, so
    // they cannot drift apart. Studio quotes these when it asks an assistant
    // for a level: an assistant told "you can jump 1 m" does not place a 3 m
    // step, and a level nobody can finish is the failure that matters here.
    //
    // `CharacterSolverTests` checks them against the simulation itself.

    /// How high a standing jump reaches, in metres: v² / 2g.
    public var maximumJumpHeight: Float {
        guard gravity < 0 else { return 0 }
        return (jumpSpeed * jumpSpeed) / (2 * -gravity)
    }

    /// How long a jump lasts, take-off to landing on the same height.
    public var airTime: Float {
        guard gravity < 0 else { return 0 }
        return 2 * jumpSpeed / -gravity
    }

    /// How far a jump carries horizontally on flat ground.
    ///
    /// The real figure is a little shorter, because air control is partial and
    /// the stick is rarely held perfectly — so a gap built to exactly this is
    /// a gap that is missed half the time. `safeJumpDistance` is what Studio
    /// quotes.
    public func maximumJumpDistance(running: Bool) -> Float {
        (running ? walkSpeed * runMultiplier : walkSpeed) * airTime
    }

    /// The gap a player clears reliably rather than occasionally: three
    /// quarters of a running jump.
    public var safeJumpDistance: Float {
        maximumJumpDistance(running: true) * 0.75
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
        surroundings: Surroundings = .normal,
        floats: Bool = false,
        deltaTime: Float
    ) -> (velocity: Vec3, yawDegrees: Float) {
        let dt = Swift.max(0, Swift.min(deltaTime, 0.1))

        switch surroundings {
        case .normal:
            break
        case let .water(surface):
            return swim(snapshot: snapshot, input: input, config: config, surface: surface, floats: floats, dt: dt)
        case .ladder:
            return climb(snapshot: snapshot, input: input, config: config, dt: dt)
        }

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

    /// Where the stick points, in the world, and how far it is pushed.
    private static func direction(_ input: MovementInput) -> (Vec3, Float) {
        let cameraYaw = Quat.yaw(degrees: input.cameraYawDegrees)
        return (cameraYaw.act(Vec3(input.stick.x, 0, -input.stick.z)).normalized, input.magnitude)
    }

    private static func turned(_ yaw: Float, toward direction: Vec3, magnitude: Float, config: MovementConfig, dt: Float) -> Float {
        guard magnitude > 0.01 else { return yaw }
        let targetYaw = atan2(direction.x, -direction.z) * 180 / .pi
        let delta = angularDelta(from: yaw, to: targetYaw)
        let maxStep = config.turnSpeedDegreesPerSecond * dt
        return normalizeDegrees(yaw + Swift.max(-maxStep, Swift.min(maxStep, delta)))
    }

    /// In water: slower, sinking gently, and jump swims up. A boat (`floats`)
    /// rides on the surface instead.
    static func swim(snapshot: PlayerSnapshot, input: MovementInput, config: MovementConfig, surface: Float, floats: Bool,
                     dt: Float) -> (velocity: Vec3, yawDegrees: Float) {
        let (direction, magnitude) = direction(input)
        let speed = config.walkSpeed * (floats ? 1.1 : 0.6) * (input.isRunning ? 1.3 : 1) * magnitude
        var horizontal = Vec3(snapshot.velocity.x, 0, snapshot.velocity.z)
        horizontal = Vec3.lerp(horizontal, direction * speed, Swift.min(1, 4 * dt))

        var vertical = snapshot.velocity.y
        let depth = surface - snapshot.position.y
        if floats {
            // Bob at the surface: the hull sits just under it.
            vertical = (depth - 0.3) * 4
        } else if input.isJumping {
            // Up towards the air; out with a hop at the top.
            vertical = depth > 1.3 ? 3.2 : config.jumpSpeed * 0.8
        } else {
            vertical = Swift.max(-2.5, vertical + config.gravity * 0.15 * dt)
        }
        let yaw = turned(snapshot.yawDegrees, toward: direction, magnitude: magnitude, config: config, dt: dt)
        return (Vec3(horizontal.x, vertical, horizontal.z), yaw)
    }

    /// On a ladder: the stick forward climbs, back climbs down, nothing
    /// holds on; jump lets go.
    static func climb(snapshot: PlayerSnapshot, input: MovementInput, config: MovementConfig,
                      dt: Float) -> (velocity: Vec3, yawDegrees: Float) {
        let (direction, magnitude) = direction(input)
        if input.isJumping {
            return (Vec3(-direction.x * 3, config.jumpSpeed * 0.8, -direction.z * 3), snapshot.yawDegrees)
        }
        let climbSpeed: Float = 3.2
        let vertical = input.stick.z * climbSpeed
        let sideways = direction * (config.walkSpeed * 0.4 * magnitude)
        let yaw = turned(snapshot.yawDegrees, toward: direction, magnitude: magnitude, config: config, dt: dt)
        return (Vec3(sideways.x, vertical, sideways.z), yaw)
    }
}
