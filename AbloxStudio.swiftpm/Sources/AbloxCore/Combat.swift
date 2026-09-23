import Foundation

/// A weapon a script can hand to a player.
public struct WeaponSpec: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var damage: Double
    /// Shots per second.
    public var fireRate: Double
    /// How far a shot reaches, in metres.
    public var range: Float
    public var magazine: Int
    /// Seconds to reload once the magazine is empty.
    public var reloadTime: Double
    /// Random cone, in degrees. 0 is a laser.
    public var spread: Float
    /// Which model the client draws. Unknown names fall back to a blaster.
    public var model: String

    public init(
        name: String,
        damage: Double = 20,
        fireRate: Double = 4,
        range: Float = 60,
        magazine: Int = 12,
        reloadTime: Double = 1.5,
        spread: Float = 1,
        model: String = "blaster"
    ) {
        self.name = name
        self.damage = damage
        self.fireRate = fireRate
        self.range = range
        self.magazine = magazine
        self.reloadTime = reloadTime
        self.spread = spread
        self.model = model
    }

    /// The same weapon with every number forced into a sane range.
    ///
    /// Scripts come from strangers. A fire rate of a million would turn one
    /// tap into a million raycasts on the host; a range of a kilometre would
    /// reach across the whole map through the kill plane. Clamped rather than
    /// refused, so a script with an enthusiastic number still works.
    public var clamped: WeaponSpec {
        var weapon = self
        weapon.name = String(name.prefix(24))
        weapon.damage = Swift.min(Swift.max(damage, 0), 1_000)
        weapon.fireRate = Swift.min(Swift.max(fireRate, 0.2), 20)
        weapon.range = Swift.min(Swift.max(range, 1), 200)
        weapon.magazine = Swift.min(Swift.max(magazine, 1), 200)
        weapon.reloadTime = Swift.min(Swift.max(reloadTime, 0), 10)
        weapon.spread = Swift.min(Swift.max(spread, 0), 30)
        return weapon
    }

    /// Weapons every script has without defining any.
    public static let presets: [String: WeaponSpec] = [
        "blaster": WeaponSpec(name: "blaster", damage: 20, fireRate: 4, range: 60, magazine: 12, reloadTime: 1.5, spread: 1, model: "blaster"),
        "rifle": WeaponSpec(name: "rifle", damage: 34, fireRate: 2, range: 120, magazine: 6, reloadTime: 2, spread: 0.2, model: "rifle"),
        "shotgun": WeaponSpec(name: "shotgun", damage: 45, fireRate: 1, range: 18, magazine: 4, reloadTime: 2.2, spread: 6, model: "shotgun"),
        "pistol": WeaponSpec(name: "pistol", damage: 15, fireRate: 5, range: 45, magazine: 10, reloadTime: 1, spread: 1.5, model: "pistol")
    ]
}

/// The shape a player occupies for the purpose of being hit: a vertical
/// capsule standing on `position`.
///
/// Matches the kinematic body `WorldCollider` uses, so what a player bumps into
/// and where they can be hit are the same size.
public struct PlayerHitBody: Sendable {
    public static let radius: Float = 0.4
    public static let height: Float = 1.8
    /// Where shots start from: roughly the eyes.
    public static let eyeHeight: Float = 1.6
}

/// Instant-hit shots, resolved on the host.
///
/// Host-authoritative on purpose. A client that decided its own hits could
/// simply decide it hit everything; the client only says where it fired from
/// and which way, and the host — with its own record of where everyone is —
/// decides what that shot met.
public enum Hitscan {

    public enum Target: Equatable, Sendable {
        case player(PeerID)
        case block(UUID)
        case nothing
    }

    public struct Result: Equatable, Sendable {
        public let target: Target
        public let point: Vec3
        public let distance: Float
    }

    /// The first thing a shot meets.
    ///
    /// Blocks stop shots: a player behind a wall cannot be hit through it,
    /// which is the difference between cover existing and not.
    public static func cast(
        from origin: Vec3,
        direction rawDirection: Vec3,
        range: Float,
        shooter: PeerID,
        players: [(peer: PeerID, position: Vec3)],
        blocks: [(id: UUID, bounds: BoundingBox)]
    ) -> Result {
        let direction = rawDirection.normalized
        guard direction.lengthSquared > 0.5, range > 0 else {
            return Result(target: .nothing, point: origin, distance: 0)
        }

        var nearest = Result(target: .nothing, point: origin + direction * range, distance: range)

        let ray = Ray(origin: origin, direction: direction)
        for block in blocks {
            if let distance = ray.intersects(block.bounds), distance >= 0, distance < nearest.distance {
                nearest = Result(target: .block(block.id), point: origin + direction * distance, distance: distance)
            }
        }

        for player in players where player.peer != shooter {
            if let distance = capsuleDistance(origin: origin, direction: direction, feet: player.position),
               distance < nearest.distance {
                nearest = Result(target: .player(player.peer), point: origin + direction * distance, distance: distance)
            }
        }

        return nearest
    }

    /// Where a ray first enters a standing player's capsule, or nil.
    ///
    /// Solved exactly rather than approximated with a box: a box is widest at
    /// its corners, so a shot that visibly passes beside someone's shoulder
    /// would count as a hit, and in a 1v1 that is the argument nobody wins.
    static func capsuleDistance(origin: Vec3, direction: Vec3, feet: Vec3) -> Float? {
        let radius = PlayerHitBody.radius
        // The capsule's spine: from one radius above the feet to one below
        // the top of the head.
        let bottom = feet + Vec3(0, radius, 0)
        let top = feet + Vec3(0, PlayerHitBody.height - radius, 0)

        var best: Float?

        // The cylinder between the two hemispheres, which is vertical, so the
        // test is a circle in XZ plus a height check.
        let ox = origin.x - bottom.x, oz = origin.z - bottom.z
        let a = direction.x * direction.x + direction.z * direction.z
        if a > 1e-8 {
            let b = 2 * (ox * direction.x + oz * direction.z)
            let c = ox * ox + oz * oz - radius * radius
            let discriminant = b * b - 4 * a * c
            if discriminant >= 0 {
                let t = (-b - discriminant.squareRoot()) / (2 * a)
                if t >= 0 {
                    let y = origin.y + direction.y * t
                    if y >= bottom.y, y <= top.y { best = t }
                }
            }
        }

        // The two hemispheres, as spheres; a hit on their inner halves is
        // already covered by the cylinder and would come out further away.
        for centre in [bottom, top] {
            if let t = sphereDistance(origin: origin, direction: direction, centre: centre, radius: radius) {
                if best == nil || t < best! { best = t }
            }
        }

        return best
    }

    static func sphereDistance(origin: Vec3, direction: Vec3, centre: Vec3, radius: Float) -> Float? {
        let offset = origin - centre
        let b = offset.dot(direction)
        let c = offset.dot(offset) - radius * radius
        let discriminant = b * b - c
        guard discriminant >= 0 else { return nil }
        let t = -b - discriminant.squareRoot()
        return t >= 0 ? t : nil
    }

    /// A direction nudged randomly within a cone of `spread` degrees.
    public static func spread(_ direction: Vec3, degrees: Float, random: inout ScriptRandom) -> Vec3 {
        guard degrees > 0 else { return direction.normalized }
        let yaw = (Float(random.unit()) * 2 - 1) * degrees
        let pitch = (Float(random.unit()) * 2 - 1) * degrees
        return Quat.euler(degrees: Vec3(pitch, yaw, 0)).act(direction.normalized).normalized
    }
}

/// What the host tracks for one player's weapon, and the checks a shot must
/// pass before it is believed.
public struct ArmedState: Equatable, Sendable {
    public var weapon: WeaponSpec
    public var ammo: Int
    public var lastShot: Double = -.infinity
    /// When the reload finishes, while reloading.
    public var reloadEnds: Double?

    public init(weapon: WeaponSpec) {
        self.weapon = weapon.clamped
        self.ammo = self.weapon.magazine
    }

    public var isReloading: Bool { reloadEnds != nil }

    /// Why a shot was refused.
    public enum Refusal: Equatable, Sendable {
        case tooSoon
        case reloading
        case tooFarFromBody
        case badDirection
    }

    /// Network jitter: two shots sent at exactly the fire rate can arrive
    /// closer together than that. Without some slack an honest player loses
    /// every third shot on a busy network.
    public static let rateTolerance = 0.35

    /// How far a claimed muzzle can be from where the host thinks the
    /// shooter's eyes are. Covers a transform or two of lag at a sprint, and
    /// not much more — enough to stop a client firing from across the map.
    public static let maximumOriginError: Float = 2.5

    public func refusal(at time: Double, origin: Vec3, direction: Vec3, shooterFeet: Vec3) -> Refusal? {
        if reloadEnds != nil { return .reloading }
        let interval = 1 / weapon.fireRate
        if time - lastShot < interval * (1 - ArmedState.rateTolerance) { return .tooSoon }
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
              direction.lengthSquared > 0.25 else { return .badDirection }
        let eyes = shooterFeet + Vec3(0, PlayerHitBody.eyeHeight, 0)
        guard origin.distance(to: eyes) <= ArmedState.maximumOriginError else { return .tooFarFromBody }
        return nil
    }

    /// Spends a round. Starts a reload when that was the last one.
    public mutating func shoot(at time: Double) {
        lastShot = time
        ammo -= 1
        if ammo <= 0 {
            ammo = 0
            reloadEnds = time + weapon.reloadTime
        }
    }

    /// Starts a reload before the magazine is empty. False when one is
    /// already running or there is nothing to reload.
    @discardableResult
    public mutating func startReload(at time: Double) -> Bool {
        guard reloadEnds == nil, ammo < weapon.magazine else { return false }
        reloadEnds = time + weapon.reloadTime
        return true
    }

    /// Finishes a reload that has run its time. Returns true when it did.
    @discardableResult
    public mutating func advance(to time: Double) -> Bool {
        guard let ends = reloadEnds, time >= ends else { return false }
        reloadEnds = nil
        ammo = weapon.magazine
        return true
    }
}
