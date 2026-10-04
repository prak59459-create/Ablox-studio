import Foundation

// Swimming and climbing, in a file of its own, split from
// WorldFeatures.swift: a change here rebuilds only the files that use what
// is here, not every file that uses anything that was declared beside it.

/// Where the player is, for how they move.
public enum Surroundings: Equatable, Sendable {
    case normal
    /// In water, whose top is at `surface`.
    case water(surface: Float)
    /// Against a ladder.
    case ladder

    /// Water around the chest, or a ladder within reach.
    public static func find(at position: Vec3, body: CharacterBody, in index: WorldIndex) -> Surroundings {
        let reach = body.bounds(at: position).expanded(by: 0.3)
        let chest = Vec3(position.x, position.y + body.height * 0.45, position.z)
        for entry in index.entries(near: reach) where entry.isVisible {
            if entry.isLiquid, entry.bounds.contains(chest) {
                return .water(surface: entry.bounds.max.y)
            }
            if entry.behavior == .ladder, reach.penetrates(entry.bounds) {
                return .ladder
            }
        }
        return .normal
    }
}
