import Foundation

// What a block does, in a file of its own, split from BlockData.swift: a
// change here rebuilds only the files that use what is here, not every file
// that uses anything that was declared beside it.

/// Gameplay meaning attached to a block. This is the bridge between the
/// Studio's authoring model and the runtime: `EventRuntime` reads it to decide
/// what a touch actually does, without needing a rule for every common case.
public enum BlockBehavior: String, Codable, CaseIterable, Sendable, ComparedByCase {
    /// Inert scenery.
    case none
    /// Players spawn (and respawn) at this block's top face.
    case spawn
    /// Touching it updates the player's respawn point.
    case checkpoint
    /// Touching it sends the player back to their respawn point.
    case hazard
    /// Touching it awards `scoreValue` and hides the block for that player.
    case collectible
    /// Touching it ends the round for that player.
    case goal
    /// Inert by itself — exists so `EventRule`s can hang off it.
    case trigger

    // MARK: Gimmicks
    //
    // The no-code vocabulary: an author picks one of these in the Inspector
    // and the block does something, with no rule to write. Each is tuned by
    // `BlockData.gimmick`.

    /// Launches the player upward. A trampoline.
    case bounce
    /// Fades out shortly after being stepped on, then returns. The classic
    /// disappearing-platform trap.
    case disappear
    /// Moves the player to `gimmick.teleportTargetID`. A warp pad.
    case teleport

    // Parts that work with no script (schema 2).

    /// Players climb it instead of bumping into it.
    case ladder
    /// Opens when a player walks into it, and closes again.
    case door
    /// Moves by `gimmick.moveOffset` and back, for ever. Carries whoever
    /// stands on it.
    case elevator
    /// Touch it to ride: a car, a bike, a boat.
    case vehicle
    /// Players push it along by walking into it.
    case pushable

    public var displayName: String {
        switch self {
        case .none: return L("None")
        case .spawn: return L("Spawn Point")
        case .checkpoint: return L("Checkpoint")
        case .hazard: return L("Hazard")
        case .collectible: return L("Collectible")
        case .goal: return L("Goal")
        case .trigger: return L("Trigger")
        case .bounce: return L("Bouncy")
        case .disappear: return L("Disappearing")
        case .teleport: return L("Teleporter")
        case .ladder: return L("Ladder")
        case .door: return L("Door")
        case .elevator: return L("Moving platform")
        case .vehicle: return L("Vehicle")
        case .pushable: return L("Pushable")
        }
    }

    /// Newer than the first world format.
    public var needsSchema2: Bool {
        switch self {
        case .none, .spawn, .checkpoint, .hazard, .collectible, .goal, .trigger, .bounce, .disappear, .teleport: return false
        case .ladder, .door, .elevator, .vehicle, .pushable: return true
        }
    }

    public var symbolName: String {
        switch self {
        case .none: return "circle.dashed"
        case .spawn: return "figure.stand"
        case .checkpoint: return "flag.fill"
        case .hazard: return "exclamationmark.triangle.fill"
        case .collectible: return "star.fill"
        case .goal: return "flag.checkered"
        case .trigger: return "bolt.fill"
        case .bounce: return "arrow.up.circle.fill"
        case .disappear: return "square.dashed"
        case .teleport: return "sparkles"
        case .ladder: return "ladder"
        case .door: return "door.left.hand.open"
        case .elevator: return "arrow.up.and.down.square.fill"
        case .vehicle: return "car.fill"
        case .pushable: return "shippingbox.fill"
        }
    }

    /// One sentence on what this does to a player who touches the block.
    ///
    /// Written once here rather than in the Inspector, because Studio's
    /// map-making guide explains the same list — and a behaviour explained two
    /// different ways in the same app is worse than one explained badly.
    /// Adding a case forces a sentence to be written for it.
    public var guidance: String {
        switch self {
        case .none: return L("Ordinary scenery. Players can stand on it and nothing else happens.")
        case .spawn: return L("Players start on top of this block.")
        case .checkpoint: return L("Touching it sets where the player respawns. Players walk through it.")
        case .hazard: return L("Touching it sends the player back to their last checkpoint.")
        case .collectible: return L("Each player can collect it once. Players walk through it.")
        case .goal: return L("Touching it ends the round for everyone.")
        case .trigger: return L("Does nothing by itself — add a rule that listens for it.")
        case .bounce: return L("Launches anyone who lands on it. A trampoline.")
        case .disappear: return L("Vanishes shortly after it is stepped on, then comes back.")
        case .teleport: return L("Moves the player to another block. Players walk through it.")
        case .ladder: return L("Walk into it and push forward to climb. Jump to let go.")
        case .door: return L("Opens when a player walks into it, then closes again after a few seconds.")
        case .elevator: return L("Moves to a spot and back again, over and over, carrying anyone standing on it.")
        case .vehicle: return L("Touch it to get in and drive faster. Tap Get out to leave it.")
        case .pushable: return L("Players push it along by walking into it. It falls off edges.")
        }
    }

    /// Whether the runtime must be told when a player touches this block.
    public var needsTouchDetection: Bool {
        switch self {
        case .none, .spawn: return false
        case .checkpoint, .hazard, .collectible, .goal, .trigger: return true
        // Every gimmick fires on contact, so the runtime has to be told.
        case .bounce, .disappear, .teleport: return true
        case .door, .vehicle, .pushable: return true
        // Worked out on each iPad as the player moves.
        case .ladder, .elevator: return false
        }
    }

    /// Whether this behaviour is one of the no-code gimmicks, which share the
    /// `BlockData.gimmick` tuning and a per-block cooldown.
    public var isGimmick: Bool {
        switch self {
        case .bounce, .disappear, .teleport, .door, .vehicle, .pushable: return true
        case .none, .spawn, .checkpoint, .hazard, .collectible, .goal, .trigger, .ladder, .elevator: return false
        }
    }
}
