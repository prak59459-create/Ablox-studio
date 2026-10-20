import Foundation

/// The slide button every game has (8.5): a second on your back, feet first,
/// the way you were going and half as fast again, then a moment to get up.
///
/// It is a move of the player's own iPad, like walking: the character solver
/// keeps the speed (`slides:`), and the other iPads see the pose from a
/// gesture (`Gesture.slide`). A game that shows its own button with the id
/// `slide` (Clash Duels) keeps its own, and this one steps aside.
public struct QuickSlide: Sendable, Equatable {
    /// Seconds on the ground.
    public static let duration: Float = 1
    /// Seconds after getting up before the next one.
    public static let rest: Float = 1.2
    /// How much faster than now (or than walking, from a stand).
    public static let boost: Float = 1.5
    /// The id a game's own slide button has.
    public static let gameButtonID = "slide"

    /// Seconds of this slide still to go; 0 when not sliding.
    public private(set) var remaining: Float = 0
    /// Seconds until the next one may start.
    public private(set) var cooldown: Float = 0

    public init() {}

    public var isSliding: Bool { remaining > 0 }

    /// Whether a slide may start now: not frozen by the game, not in a
    /// vehicle or on a ride, not swimming or climbing.
    public static func allowed(frozen: Bool, ride: AvatarProfile.Ride, surroundings: Surroundings, speedScale: Float) -> Bool {
        guard !frozen, ride == .none, speedScale > 0 else { return false }
        if case .normal = surroundings { return true }
        return false
    }

    /// Starts a slide when the last one has rested, and gives the velocity
    /// it starts with: along the ground the way they were going, or the way
    /// they face (`yawDegrees`) when standing still. Up and down are kept,
    /// so a slide off a jump still falls. Nil when it cannot start yet.
    public mutating func start(velocity: Vec3, yawDegrees: Float, walkSpeed: Float) -> Vec3? {
        guard remaining <= 0, cooldown <= 0 else { return nil }
        let flat = Vec3(velocity.x, 0, velocity.z)
        let speed = flat.length
        let direction: Vec3
        if speed > 1 {
            direction = flat.normalized
        } else {
            let radians = yawDegrees * .pi / 180
            direction = Vec3(sin(radians), 0, -cos(radians))
        }
        let slideSpeed = Swift.max(speed, walkSpeed) * Self.boost
        remaining = Self.duration
        cooldown = Self.duration + Self.rest
        return Vec3(direction.x * slideSpeed, velocity.y, direction.z * slideSpeed)
    }

    /// Time passing.
    public mutating func advance(by seconds: Float) {
        let dt = Swift.max(0, seconds)
        remaining = Swift.max(0, remaining - dt)
        cooldown = Swift.max(0, cooldown - dt)
    }

    /// Up at once: the game froze them, they went into water, got on a ride.
    public mutating func stop() {
        remaining = 0
    }
}
