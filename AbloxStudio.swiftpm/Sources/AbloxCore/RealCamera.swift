import Foundation

/// Real mode (the play menu): a first-person camera that moves like a head
/// does. Each step bobs it up and down and a little side to side, turning
/// tips it into the turn, and landing from a fall dips it and nods it down,
/// then it springs back. Worked out here, away from RealityKit, so the
/// numbers can be tested.
public struct RealCamera: Sendable {

    /// How the eye is moved this frame, on top of where it would be.
    public struct Pose: Equatable, Sendable {
        /// Metres to the right (x) and up (y) of the plain eye.
        public var offset: Vec3
        /// Tipped clockwise (positive) about the way the camera looks.
        public var rollDegrees: Float
        /// Added to the camera's pitch (negative: looking further down).
        public var pitchDegrees: Float

        public static let still = Pose(offset: .zero, rollDegrees: 0, pitchDegrees: 0)
    }

    /// Where in the stride the head is, in radians (one step is π).
    public private(set) var stridePhase: Float = 0
    /// 0 stood still … 1 running: how much the steps show.
    public private(set) var bob: Float = 0
    /// How far down the last landing pushed the eye, in metres.
    public private(set) var dip: Float = 0
    private var dipSpeed: Float = 0
    private var turnRoll: Float = 0
    private var wasGrounded = true
    private var fallSpeed: Float = 0
    private var lastYaw: Float?

    /// The most a landing dips, and the speed that counts as running.
    public static let maximumDip: Float = 0.28
    static let runningSpeed: Float = 8

    public init() {}

    /// One frame. `yawDegrees` is where the camera faces; `gentle` (less
    /// motion, or camera shake turned off) keeps about a third of it.
    public mutating func step(velocity: Vec3, grounded: Bool, yawDegrees: Float, gentle: Bool, deltaTime: Float) -> Pose {
        let dt = max(0, min(deltaTime, 0.1))
        guard dt > 0 else { return pose(gentle: gentle) }
        let speed = Vec3(velocity.x, 0, velocity.z).length

        // Steps: faster legs the faster you go, and none in the air.
        let wanted: Float = grounded ? min(1, speed / Self.runningSpeed) : 0
        bob += (wanted - bob) * (1 - exp(-8 * dt))
        if grounded, speed > 0.3 {
            stridePhase = (stridePhase + dt * (4 + speed * 0.9)).truncatingRemainder(dividingBy: 2 * .pi * 100)
        }

        // Landing: the harder the fall, the deeper the dip.
        if !grounded { fallSpeed = min(fallSpeed, velocity.y) }
        if grounded, !wasGrounded {
            let hit = min(Self.maximumDip, max(0, -fallSpeed - 2) * 0.025)
            dip = max(dip, hit)
            dipSpeed = 0
            fallSpeed = 0
        }
        if grounded { fallSpeed = 0 }
        wasGrounded = grounded
        // A spring back up, a little bouncy.
        let pull = -dip * 120 - dipSpeed * 14
        dipSpeed += pull * dt
        dip = max(-0.04, dip + dipSpeed * dt)
        if abs(dip) < 0.0005 && abs(dipSpeed) < 0.005 { dip = 0; dipSpeed = 0 }

        // Turning tips the head into the turn.
        var rate: Float = 0
        if let lastYaw {
            var delta = yawDegrees - lastYaw
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            rate = delta / dt
        }
        lastYaw = yawDegrees
        let lean = max(-3, min(3, -rate * 0.01))
        turnRoll += (lean - turnRoll) * (1 - exp(-6 * dt))

        return pose(gentle: gentle)
    }

    /// After a teleport or a respawn: no landing from the old place.
    public mutating func reset() {
        self = RealCamera()
    }

    private func pose(gentle: Bool) -> Pose {
        let scale: Float = gentle ? 0.35 : 1
        let up = abs(sin(stridePhase)) * 0.06 * bob - 0.03 * bob
        let side = sin(stridePhase) * 0.035 * bob
        let roll = sin(stridePhase) * 0.9 * bob + turnRoll
        return Pose(
            offset: Vec3(side * scale, (up - dip) * scale, 0),
            rollDegrees: roll * scale,
            pitchDegrees: -dip * 18 * scale
        )
    }
}
