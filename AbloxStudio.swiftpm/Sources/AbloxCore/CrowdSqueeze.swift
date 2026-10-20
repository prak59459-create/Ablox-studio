import Foundation

/// Lets the player through a crowd that holds them up.
///
/// People and NPCs bump into each other, which is right for a few. With a
/// hundred on one field (Last Survivor Games) the player was boxed in and
/// could hardly move. NPCs already walk through after a second of being
/// held up; the player now slips through after half a second, and stays
/// able to until they walk freely again.
public struct CrowdSqueeze: Sendable, Equatable {

    /// How long someone may hold the player up before they slip through.
    public static let patience: Float = 0.5

    public private(set) var heldFor: Float = 0

    public init() {}

    /// Whether the player passes through characters this frame.
    public var passesThrough: Bool { heldFor > Self.patience }

    /// After a frame: how fast the player meant to walk, how fast they got,
    /// and whether other characters were in the way.
    public mutating func note(wanted: Float, got: Float, amongCharacters: Bool, deltaTime: Float) {
        let blocked = wanted > 0.5 && got < wanted * 0.3
        if blocked, amongCharacters || passesThrough {
            heldFor += Swift.max(0, deltaTime)
        } else if !blocked {
            heldFor = 0
        }
    }
}
