import Foundation

// MARK: - Trigger

/// What makes a rule fire.
///
/// Encoded with an explicit `type` discriminator rather than Swift's default
/// enum-with-payload encoding, because the default emits a nested single-key
/// object that is painful to read in a saved world and impossible to extend
/// without breaking old files.
public enum EventTrigger: Codable, Hashable, Sendable {
    /// A player's avatar touched a specific block.
    case blockTouched(blockID: UUID)
    /// A player's avatar touched any block carrying `tag`.
    case tagTouched(tag: String)
    /// A player tapped a block in Play mode.
    case blockTapped(blockID: UUID)
    /// A player came within `radius` metres (horizontally) of a block.
    case proximity(blockID: UUID, radius: Float)
    /// Fires once when the round starts.
    case worldStart
    /// Fires every `interval` seconds while the round runs.
    case timer(interval: Double)
    /// Fires when any player's score reaches `score`.
    case scoreReached(score: Int)

    private enum CodingKeys: String, CodingKey {
        case type, blockID, tag, radius, interval, score
    }

    private enum Kind: String, Codable {
        case blockTouched, tagTouched, blockTapped, proximity, worldStart, timer, scoreReached
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .blockTouched(blockID):
            try c.encode(Kind.blockTouched, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
        case let .tagTouched(tag):
            try c.encode(Kind.tagTouched, forKey: .type)
            try c.encode(tag, forKey: .tag)
        case let .blockTapped(blockID):
            try c.encode(Kind.blockTapped, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
        case let .proximity(blockID, radius):
            try c.encode(Kind.proximity, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
            try c.encode(radius, forKey: .radius)
        case .worldStart:
            try c.encode(Kind.worldStart, forKey: .type)
        case let .timer(interval):
            try c.encode(Kind.timer, forKey: .type)
            try c.encode(interval, forKey: .interval)
        case let .scoreReached(score):
            try c.encode(Kind.scoreReached, forKey: .type)
            try c.encode(score, forKey: .score)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .blockTouched:
            self = .blockTouched(blockID: try c.decode(UUID.self, forKey: .blockID))
        case .tagTouched:
            self = .tagTouched(tag: try c.decode(String.self, forKey: .tag))
        case .blockTapped:
            self = .blockTapped(blockID: try c.decode(UUID.self, forKey: .blockID))
        case .proximity:
            self = .proximity(
                blockID: try c.decode(UUID.self, forKey: .blockID),
                radius: try c.decodeIfPresent(Float.self, forKey: .radius) ?? 3
            )
        case .worldStart:
            self = .worldStart
        case .timer:
            self = .timer(interval: try c.decodeIfPresent(Double.self, forKey: .interval) ?? 1)
        case .scoreReached:
            self = .scoreReached(score: try c.decode(Int.self, forKey: .score))
        }
    }
}

public extension EventTrigger {
    var displayName: String {
        switch self {
        case .blockTouched: return "When touched"
        case let .tagTouched(tag): return "When any “\(tag)” is touched"
        case .blockTapped: return "When tapped"
        case let .proximity(_, radius): return String(format: "When a player is within %.1fm", radius)
        case .worldStart: return "When the round starts"
        case let .timer(interval): return String(format: "Every %.1fs", interval)
        case let .scoreReached(score): return "When score reaches \(score)"
        }
    }

    var symbolName: String {
        switch self {
        case .blockTouched, .tagTouched: return "hand.tap.fill"
        case .blockTapped: return "hand.point.up.left.fill"
        case .proximity: return "dot.radiowaves.left.and.right"
        case .worldStart: return "play.circle.fill"
        case .timer: return "timer"
        case .scoreReached: return "star.circle.fill"
        }
    }

    var referencedBlockIDs: [UUID] {
        switch self {
        case let .blockTouched(id), let .blockTapped(id), let .proximity(id, _):
            return [id]
        case .tagTouched, .worldStart, .timer, .scoreReached:
            return []
        }
    }
}

// MARK: - Action

/// What a rule does when it fires.
public enum EventAction: Codable, Hashable, Sendable {
    /// Fades a block to a colour over `duration` seconds.
    case tint(blockID: UUID, color: ColorRGBA, duration: Double)
    /// Slides a block by an offset, in world space, over `duration` seconds.
    case move(blockID: UUID, offset: Vec3, duration: Double)
    /// Shows or hides a block.
    case setVisible(blockID: UUID, visible: Bool)
    /// Turns collision on or off — the basis of disappearing-floor puzzles.
    case setCollision(blockID: UUID, enabled: Bool)
    /// Moves the triggering player somewhere.
    case teleportPlayer(to: Vec3)
    /// Adds (or, when negative, removes) points from the triggering player.
    case awardPoints(Int)
    /// Banner text shown to everyone.
    case announce(message: String, duration: Double)
    /// A named sound effect the client maps to a system sound.
    case playSound(name: String)
    /// Ends the round.
    case endRound(message: String)
    /// Launches the triggering player upward at `speed` m/s. The client owns
    /// the impulse — the host has no simulation to apply it to.
    case bouncePlayer(speed: Float)

    private enum CodingKeys: String, CodingKey {
        case type, blockID, color, duration, offset, visible, enabled, position, points, message, name, speed
    }

    private enum Kind: String, Codable {
        case tint, move, setVisible, setCollision, teleportPlayer, awardPoints, announce, playSound, endRound, bouncePlayer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tint(blockID, color, duration):
            try c.encode(Kind.tint, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
            try c.encode(color, forKey: .color)
            try c.encode(duration, forKey: .duration)
        case let .move(blockID, offset, duration):
            try c.encode(Kind.move, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
            try c.encode(offset, forKey: .offset)
            try c.encode(duration, forKey: .duration)
        case let .setVisible(blockID, visible):
            try c.encode(Kind.setVisible, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
            try c.encode(visible, forKey: .visible)
        case let .setCollision(blockID, enabled):
            try c.encode(Kind.setCollision, forKey: .type)
            try c.encode(blockID, forKey: .blockID)
            try c.encode(enabled, forKey: .enabled)
        case let .teleportPlayer(position):
            try c.encode(Kind.teleportPlayer, forKey: .type)
            try c.encode(position, forKey: .position)
        case let .awardPoints(points):
            try c.encode(Kind.awardPoints, forKey: .type)
            try c.encode(points, forKey: .points)
        case let .announce(message, duration):
            try c.encode(Kind.announce, forKey: .type)
            try c.encode(message, forKey: .message)
            try c.encode(duration, forKey: .duration)
        case let .playSound(name):
            try c.encode(Kind.playSound, forKey: .type)
            try c.encode(name, forKey: .name)
        case let .endRound(message):
            try c.encode(Kind.endRound, forKey: .type)
            try c.encode(message, forKey: .message)
        case let .bouncePlayer(speed):
            try c.encode(Kind.bouncePlayer, forKey: .type)
            try c.encode(speed, forKey: .speed)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .tint:
            self = .tint(
                blockID: try c.decode(UUID.self, forKey: .blockID),
                color: try c.decode(ColorRGBA.self, forKey: .color),
                duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            )
        case .move:
            self = .move(
                blockID: try c.decode(UUID.self, forKey: .blockID),
                offset: try c.decode(Vec3.self, forKey: .offset),
                duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            )
        case .setVisible:
            self = .setVisible(
                blockID: try c.decode(UUID.self, forKey: .blockID),
                visible: try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            )
        case .setCollision:
            self = .setCollision(
                blockID: try c.decode(UUID.self, forKey: .blockID),
                enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            )
        case .teleportPlayer:
            self = .teleportPlayer(to: try c.decode(Vec3.self, forKey: .position))
        case .awardPoints:
            self = .awardPoints(try c.decode(Int.self, forKey: .points))
        case .announce:
            self = .announce(
                message: try c.decode(String.self, forKey: .message),
                duration: try c.decodeIfPresent(Double.self, forKey: .duration) ?? 2
            )
        case .playSound:
            self = .playSound(name: try c.decode(String.self, forKey: .name))
        case .endRound:
            self = .endRound(message: try c.decodeIfPresent(String.self, forKey: .message) ?? "Round over")
        case .bouncePlayer:
            self = .bouncePlayer(speed: try c.decodeIfPresent(Float.self, forKey: .speed) ?? 14)
        }
    }
}

public extension EventAction {
    var displayName: String {
        switch self {
        case .tint: return "Change colour"
        case .move: return "Move"
        case let .setVisible(_, visible): return visible ? "Show" : "Hide"
        case let .setCollision(_, enabled): return enabled ? "Enable collision" : "Disable collision"
        case .teleportPlayer: return "Teleport player"
        case let .awardPoints(points): return points >= 0 ? "Award \(points) points" : "Remove \(-points) points"
        case .announce: return "Announce"
        case .playSound: return "Play sound"
        case .endRound: return "End round"
        case let .bouncePlayer(speed): return String(format: "Bounce player (%.0f m/s)", speed)
        }
    }

    var symbolName: String {
        switch self {
        case .tint: return "paintpalette.fill"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .setVisible: return "eye.fill"
        case .setCollision: return "shield.lefthalf.filled"
        case .teleportPlayer: return "sparkles"
        case .awardPoints: return "star.fill"
        case .announce: return "megaphone.fill"
        case .playSound: return "speaker.wave.2.fill"
        case .endRound: return "flag.checkered"
        case .bouncePlayer: return "arrow.up.circle.fill"
        }
    }

    var referencedBlockIDs: [UUID] {
        switch self {
        case let .tint(id, _, _), let .move(id, _, _), let .setVisible(id, _), let .setCollision(id, _):
            return [id]
        case .teleportPlayer, .awardPoints, .announce, .playSound, .endRound, .bouncePlayer:
            return []
        }
    }
}

// MARK: - EventRule

/// One trigger plus the actions it runs. The whole scripting surface of Ablox
/// — no text scripting language, because typing code on an iPad is miserable
/// and a fixed vocabulary can be edited with pickers.
public struct EventRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: EventTrigger
    public var actions: [EventAction]

    /// How many times this rule may fire in a round. `nil` means unlimited.
    /// A one-shot collectible is `maxFireCount == 1`.
    public var maxFireCount: Int?

    /// Minimum seconds between firings. Stops a rule bound to a touch trigger
    /// from firing every physics tick while a player stands on the block.
    public var cooldown: Double

    public init(
        id: UUID = UUID(),
        name: String = "New Rule",
        isEnabled: Bool = true,
        trigger: EventTrigger = .worldStart,
        actions: [EventAction] = [],
        maxFireCount: Int? = nil,
        cooldown: Double = 0.5
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.actions = actions
        self.maxFireCount = maxFireCount
        self.cooldown = cooldown
    }

    public var referencedBlockIDs: [UUID] {
        trigger.referencedBlockIDs + actions.flatMap(\.referencedBlockIDs)
    }

    public func references(anyOf ids: Set<UUID>) -> Bool {
        referencedBlockIDs.contains { ids.contains($0) }
    }

    public var summary: String {
        let actionText = actions.isEmpty
            ? "do nothing"
            : actions.map(\.displayName).joined(separator: ", ")
        return "\(trigger.displayName) → \(actionText)"
    }
}

public extension EventRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Rule"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        trigger = try c.decode(EventTrigger.self, forKey: .trigger)
        actions = try c.decodeIfPresent([EventAction].self, forKey: .actions) ?? []
        maxFireCount = try c.decodeIfPresent(Int.self, forKey: .maxFireCount)
        cooldown = try c.decodeIfPresent(Double.self, forKey: .cooldown) ?? 0.5
    }
}
