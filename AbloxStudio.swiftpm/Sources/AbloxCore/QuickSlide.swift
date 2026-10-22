import Foundation

/// The slide button every game has (8.5): a second on your back, feet first,
/// the way you were going and half as fast again, then a moment to get up.
///
/// Down a slope (8.8) it lasts all the way to the bottom, and keeps going two
/// seconds more on the ground after it. A slope is the ground falling away
/// under a slide that is still on it (`advance(by:descended:grounded:)`):
/// every slope in Ablox is steps or a tilted box, so the feet drop a little
/// at a time rather than leaving the ground for long.
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
    /// Seconds still to go when a slope ends, on the flat ground after it.
    public static let afterSlope: Float = 2
    /// Seconds with no drop before the slope counts as ended.
    public static let slopeGrace: Float = 0.3
    /// Metres a frame's drop must pass to count as going down a slope.
    public static let minimumDrop: Float = 0.002
    /// Seconds off the ground that still count as on the slope (a step down
    /// is a short fall); a longer fall is a jump, not a slope.
    public static let airGrace: Float = 0.25

    /// Seconds of this slide still to go; 0 when not sliding.
    public private(set) var remaining: Float = 0
    /// Seconds until the next one may start.
    public private(set) var cooldown: Float = 0
    /// Going down a slope now: the slide lasts until the slope ends.
    public private(set) var onSlope = false
    /// Seconds since the feet last dropped, while on a slope.
    private var sinceDrop: Float = 0
    /// Seconds since the feet were last on the ground.
    private var sinceGround: Float = 0

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
        onSlope = false
        sinceDrop = 0
        return Vec3(direction.x * slideSpeed, velocity.y, direction.z * slideSpeed)
    }

    /// Time passing. `descended` is how far the feet went down since the
    /// last call (metres, up is negative) and `grounded` whether they are on
    /// the ground: a slide that keeps dropping while on the ground is on a
    /// slope, and goes on until the slope ends, then `afterSlope` more.
    /// Returns true when the slide was made longer, so the pose can follow.
    @discardableResult
    public mutating func advance(by seconds: Float, descended: Float = 0, grounded: Bool = true) -> Bool {
        let dt = Swift.max(0, seconds)
        sinceGround = grounded ? 0 : sinceGround + dt
        var longer = false
        if remaining > 0 {
            if sinceGround > Self.airGrace {
                // Off an edge and falling: a jump, not a slope.
                onSlope = false
            } else if descended > Self.minimumDrop {
                onSlope = true
                sinceDrop = 0
            } else if onSlope {
                sinceDrop += dt
                if sinceDrop >= Self.slopeGrace {
                    // Off the bottom: two seconds along the ground, counted
                    // from the last drop.
                    onSlope = false
                    remaining = Swift.max(remaining, Self.afterSlope - sinceDrop + dt)
                    longer = true
                }
            }
            if onSlope, remaining < Self.slopeGrace + dt {
                remaining = Self.slopeGrace + dt
                longer = true
            }
            cooldown = Swift.max(cooldown, remaining + Self.rest)
        }
        remaining = Swift.max(0, remaining - dt)
        cooldown = Swift.max(0, cooldown - dt)
        if remaining <= 0 { onSlope = false }
        return longer
    }

    /// Up at once: the game froze them, they went into water, got on a ride.
    public mutating func stop() {
        remaining = 0
        onSlope = false
    }
}
