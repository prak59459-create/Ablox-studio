import Foundation

// How a block that does something is tuned, in a file of its own, split from
// BlockData.swift: a change here rebuilds only the files that use what is
// here, not every file that uses anything that was declared beside it.

/// Parameters for the no-code gimmick behaviours.
///
/// Gathered into one struct rather than five loose fields on `BlockData`,
/// because they are only meaningful together and only when `behavior` is a
/// gimmick. That keeps `BlockData` readable and keeps a world file from
/// carrying five nulls on every inert block.
public struct GimmickSettings: Codable, Hashable, Sendable {

    /// Upward speed, in m/s, imparted by a `.bounce` block.
    ///
    /// Default is comfortably above `MovementConfig.jumpSpeed`, so a
    /// trampoline always feels like more than a jump.
    public var bounceSpeed: Float

    /// Seconds between a `.disappear` block being stepped on and it going.
    /// The grace period is the whole point — zero would be an instant
    /// trapdoor, which reads as a bug rather than a trap.
    public var disappearDelay: Double

    /// Seconds a `.disappear` block stays gone before returning.
    public var respawnDelay: Double

    /// Where a `.teleport` block sends the player. The player arrives above
    /// this block's top face. A nil or dangling target makes the block inert
    /// rather than dropping the player through the world.
    public var teleportTargetID: UUID?

    /// Minimum seconds between firings of this specific block.
    ///
    /// Without it a gimmick re-triggers on every contact report while the
    /// player stands on it — a bounce pad would fire dozens of times a second
    /// and fling the player into orbit.
    public var cooldown: Double

    /// How long a `.door` stays open.
    public var doorSeconds: Double
    /// Where a `.elevator` goes, from where it was built.
    public var moveOffset: Vec3
    /// Seconds a `.elevator` takes each way, and waits at each end.
    public var moveSeconds: Double
    public var movePause: Double
    /// What a `.vehicle` is (`AvatarProfile.Ride`), and how much faster it goes.
    public var vehicle: String
    public var vehicleSpeed: Float
    /// A `.checkpoint`'s place in the course: touching an earlier one after a
    /// later one does not move the player back. 0 counts in any order.
    public var stage: Int

    public init(
        bounceSpeed: Float = 14,
        disappearDelay: Double = 0.3,
        respawnDelay: Double = 3.0,
        teleportTargetID: UUID? = nil,
        cooldown: Double = 1.5,
        doorSeconds: Double = 3,
        moveOffset: Vec3 = Vec3(0, 6, 0),
        moveSeconds: Double = 3,
        movePause: Double = 1.5,
        vehicle: String = "car",
        vehicleSpeed: Float = 2,
        stage: Int = 0
    ) {
        self.bounceSpeed = bounceSpeed
        self.disappearDelay = disappearDelay
        self.respawnDelay = respawnDelay
        self.teleportTargetID = teleportTargetID
        self.cooldown = cooldown
        self.doorSeconds = doorSeconds
        self.moveOffset = moveOffset
        self.moveSeconds = moveSeconds
        self.movePause = movePause
        self.vehicle = vehicle
        self.vehicleSpeed = vehicleSpeed
        self.stage = stage
    }

    public static let `default` = GimmickSettings()

    private enum CodingKeys: String, CodingKey {
        case bounceSpeed, disappearDelay, respawnDelay, teleportTargetID, cooldown
        case doorSeconds, moveOffset, moveSeconds, movePause, vehicle, vehicleSpeed, stage
    }

    // Written by hand so settings saved before a field existed still load,
    // and the newer fields are only written when they are set.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GimmickSettings()
        bounceSpeed = try c.decodeIfPresent(Float.self, forKey: .bounceSpeed) ?? d.bounceSpeed
        disappearDelay = try c.decodeIfPresent(Double.self, forKey: .disappearDelay) ?? d.disappearDelay
        respawnDelay = try c.decodeIfPresent(Double.self, forKey: .respawnDelay) ?? d.respawnDelay
        teleportTargetID = try c.decodeIfPresent(UUID.self, forKey: .teleportTargetID)
        cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldown) ?? d.cooldown
        doorSeconds = (try? c.decodeIfPresent(Double.self, forKey: .doorSeconds)) ?? d.doorSeconds
        moveOffset = (try? c.decodeIfPresent(Vec3.self, forKey: .moveOffset)) ?? d.moveOffset
        moveSeconds = (try? c.decodeIfPresent(Double.self, forKey: .moveSeconds)) ?? d.moveSeconds
        movePause = (try? c.decodeIfPresent(Double.self, forKey: .movePause)) ?? d.movePause
        vehicle = (try? c.decodeIfPresent(String.self, forKey: .vehicle)) ?? d.vehicle
        vehicleSpeed = (try? c.decodeIfPresent(Float.self, forKey: .vehicleSpeed)) ?? d.vehicleSpeed
        stage = (try? c.decodeIfPresent(Int.self, forKey: .stage)) ?? d.stage
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let d = GimmickSettings()
        try c.encode(bounceSpeed, forKey: .bounceSpeed)
        try c.encode(disappearDelay, forKey: .disappearDelay)
        try c.encode(respawnDelay, forKey: .respawnDelay)
        try c.encodeIfPresent(teleportTargetID, forKey: .teleportTargetID)
        try c.encode(cooldown, forKey: .cooldown)
        if doorSeconds != d.doorSeconds { try c.encode(doorSeconds, forKey: .doorSeconds) }
        if moveOffset != d.moveOffset { try c.encode(moveOffset, forKey: .moveOffset) }
        if moveSeconds != d.moveSeconds { try c.encode(moveSeconds, forKey: .moveSeconds) }
        if movePause != d.movePause { try c.encode(movePause, forKey: .movePause) }
        if vehicle != d.vehicle { try c.encode(vehicle, forKey: .vehicle) }
        if vehicleSpeed != d.vehicleSpeed { try c.encode(vehicleSpeed, forKey: .vehicleSpeed) }
        if stage != d.stage { try c.encode(stage, forKey: .stage) }
    }
}
