import Foundation
import RealityKit
import simd
import AbloxCore

// How the body moves when no emote is playing: walking and running with the
// limbs swinging from the shoulder and hip, jumping with the arms thrown up,
// falling with them spread, breathing while stood still, and a pose for each
// ride. Every limb eases toward where it is going, so changing from one to
// the next never snaps. Kept apart from `AvatarEntity` so it compiles on its
// own.

/// Where the limbs are and how fast the avatar is going up or down.
struct LimbState {
    /// Forward swing of each arm and leg about the shoulder or hip, in
    /// radians (positive: the hand or foot goes forward). Left, right.
    var armSwing = SIMD2<Float>(0, 0)
    var legSwing = SIMD2<Float>(0, 0)
    /// How far each arm or leg is out to the side (positive: away from the body).
    var armSpread = SIMD2<Float>(0, 0)
    var legSpread = SIMD2<Float>(0, 0)
    /// Leaning forward while running, in radians.
    var lean: Float = 0
    /// Height last frame, for the vertical speed; nil after a teleport.
    var previousHeight: Float?
    /// Metres a second, smoothed; positive going up.
    var verticalSpeed: Float = 0
    /// Seconds rising or falling fast enough to count as in the air.
    var airTime: Float = 0
    /// Breathing and swaying while stood still.
    var breath: Float = 0

    /// Back to standing, as after an emote.
    mutating func settle() {
        armSwing = .zero
        legSwing = .zero
        armSpread = .zero
        legSpread = .zero
        lean = 0
    }
}

/// What the body is doing this frame.
enum BodyMove: Equatable {
    case standing, walking, jumping, falling, riding
}

extension AvatarEntity {

    /// Shoulders and hips: where the arms and legs hang from.
    static let shoulderX: Float = 0.42
    static let shoulderY: Float = 1.25
    static let hipX: Float = 0.15
    static let hipY: Float = 0.6
    static let limbLength: Float = 0.6

    /// Climbing faster than this is a jump; dropping faster, a fall.
    static let airSpeed: Float = 2.2

    // MARK: Up and down

    /// The vertical speed from how the height changed: what tells a jump
    /// from a fall, for this avatar and for everyone else's alike.
    func trackHeight(deltaTime: Float) {
        let height = position.y
        defer { limbs.previousHeight = height }
        guard let previous = limbs.previousHeight, deltaTime > 1e-4 else { return }
        let raw = (height - previous) / deltaTime
        // A step this big is a teleport or a respawn, not a jump.
        guard abs(raw) < 40 else {
            limbs.verticalSpeed = 0
            limbs.airTime = 0
            return
        }
        limbs.verticalSpeed += (raw - limbs.verticalSpeed) * (1 - exp(-14 * deltaTime))
        if abs(limbs.verticalSpeed) > Self.airSpeed {
            limbs.airTime += deltaTime
        } else {
            limbs.airTime = 0
        }
    }

    var bodyMove: BodyMove {
        if appliedRideKind != .none && appliedRideKind != .jetpack { return .riding }
        // A moment in the air before it counts, so steps and slopes do not flap the arms.
        if limbs.airTime > 0.12 {
            return limbs.verticalSpeed > 0 ? .jumping : .falling
        }
        return .standing
    }

    // MARK: The pose

    /// Sets this frame's arms, legs and lean, eased toward the pose for what
    /// the body is doing.
    func poseBody(speed: Float, deltaTime: Float) {
        // Wrapped, so hours of play keep the sway smooth.
        limbs.breath = (limbs.breath + deltaTime).truncatingRemainder(dividingBy: 600)
        var move = bodyMove
        if move == .standing && speed > 0.2 { move = .walking }
        let target = targetPose(for: move, speed: speed)
        // Quick enough to follow the stride, slow enough to blend.
        let rate: Float = move == .walking ? 26 : 12
        let ease: Float = 1 - exp(-rate * deltaTime)
        limbs.armSwing += (target.armSwing - limbs.armSwing) * ease
        limbs.legSwing += (target.legSwing - limbs.legSwing) * ease
        limbs.armSpread += (target.armSpread - limbs.armSpread) * ease
        limbs.legSpread += (target.legSpread - limbs.legSpread) * ease
        limbs.lean += (target.lean - limbs.lean) * ease
        applyLimbs()
    }

    private func targetPose(for move: BodyMove, speed: Float) -> LimbState {
        var pose = LimbState()
        switch move {
        case .standing:
            // Breathing: the arms drift a little away and back.
            let breath: Float = sin(limbs.breath * 2.1)
            pose.armSwing = SIMD2<Float>(0.03, 0.03) * breath
            pose.armSpread = SIMD2<Float>(0.06, 0.06) + SIMD2<Float>(0.025, 0.025) * breath
        case .walking:
            // Phase from distance, so the stride matches the ground covered.
            let phase: Float = strideDistanceForPose * 3.0
            let amplitude: Float = Swift.min(0.85, 0.1 * speed)
            let swing: Float = sin(phase) * amplitude
            pose.legSwing = SIMD2<Float>(swing, -swing)
            pose.armSwing = SIMD2<Float>(-swing, swing) * 0.9
            pose.armSpread = SIMD2<Float>(0.05, 0.05)
            // Running leans into it.
            pose.lean = speed > 6.5 ? Swift.min(0.16, (speed - 6.5) * 0.05 + 0.06) : 0
        case .jumping:
            // Arms thrown up, one knee forward.
            pose.armSwing = SIMD2<Float>(2.75, 2.75)
            pose.armSpread = SIMD2<Float>(0.18, 0.18)
            pose.legSwing = SIMD2<Float>(0.45, -0.12)
        case .falling:
            // Arms up and out, legs apart, flailing a little.
            let flail: Float = sin(limbs.breath * 9) * 0.12
            pose.armSwing = SIMD2<Float>(2.3 + flail, 2.3 - flail)
            pose.armSpread = SIMD2<Float>(0.75, 0.75)
            pose.legSwing = SIMD2<Float>(0.25 - flail, -0.2 + flail)
            pose.legSpread = SIMD2<Float>(0.14, 0.14)
        case .riding:
            pose = ridePose(speed: speed)
        }
        return pose
    }

    /// Hands on the wheel or the handlebars, pedalling, balancing.
    private func ridePose(speed: Float) -> LimbState {
        var pose = LimbState()
        switch appliedRideKind {
        case .car, .sports, .truck, .kart:
            // Both hands on the wheel, a little turn when moving.
            let steer: Float = speed > 0.5 ? sin(limbs.breath * 1.3) * 0.06 : 0
            pose.armSwing = SIMD2<Float>(1.25 + steer, 1.25 - steer)
            pose.armSpread = SIMD2<Float>(-0.18, -0.18)
        case .bike:
            let phase: Float = strideDistanceForPose * 2.2
            let pedal: Float = speed > 0.3 ? sin(phase) * 0.45 : 0
            pose.armSwing = SIMD2<Float>(1.05, 1.05)
            pose.armSpread = SIMD2<Float>(0.08, 0.08)
            pose.legSwing = SIMD2<Float>(0.75 + pedal, 0.75 - pedal)
            pose.lean = 0.12
        case .scooter:
            pose.armSwing = SIMD2<Float>(1.0, 1.0)
            pose.armSpread = SIMD2<Float>(0.1, 0.1)
            pose.legSwing = SIMD2<Float>(0.1, -0.15)
        case .hoverboard:
            // Arms out for balance, swaying.
            let sway: Float = sin(limbs.breath * 1.8) * 0.12
            pose.armSwing = SIMD2<Float>(0.25, 0.25)
            pose.armSpread = SIMD2<Float>(0.95 + sway, 0.95 - sway)
            pose.legSpread = SIMD2<Float>(0.12, 0.12)
            pose.lean = speed > 4 ? 0.1 : 0
        case .jetpack, .none:
            break
        }
        return pose
    }

    /// Puts each limb where its swing and spread say, turning about the
    /// shoulder or hip rather than the middle of the limb.
    private func applyLimbs() {
        let half = SIMD3<Float>(0, -Self.limbLength / 2, 0)
        for (index, arm) in [leftArm, rightArm].enumerated() {
            let side: Float = index == 0 ? -1 : 1
            let turn = limbTurn(swing: limbs.armSwing[index], spread: limbs.armSpread[index] * side)
            arm.orientation = turn
            arm.position = SIMD3<Float>(side * Self.shoulderX, Self.shoulderY, 0) + turn.act(half)
        }
        for (index, leg) in [leftLeg, rightLeg].enumerated() {
            let side: Float = index == 0 ? -1 : 1
            let turn = limbTurn(swing: limbs.legSwing[index], spread: limbs.legSpread[index] * side)
            leg.orientation = turn
            leg.position = SIMD3<Float>(side * Self.hipX, Self.hipY, 0) + turn.act(half)
        }
        // Leaning forward tips the top toward the front (-Z), about the feet.
        rig.orientation = simd_quatf(angle: -limbs.lean, axis: Self.sideways)
        // The head leans back by as much, so it keeps looking ahead instead
        // of at the ground while running or riding. Looking about when idle
        // (`lookAbout`) sets the head after this.
        head.orientation = simd_quatf(angle: limbs.lean, axis: Self.sideways)
    }

    /// Swinging forward (about X: the avatar faces -Z, so a positive angle
    /// takes the hand or foot forward) and then out to the side (about Z).
    private func limbTurn(swing: Float, spread: Float) -> simd_quatf {
        simd_quatf(angle: spread, axis: Self.forwards) * simd_quatf(angle: swing, axis: Self.sideways)
    }
}
