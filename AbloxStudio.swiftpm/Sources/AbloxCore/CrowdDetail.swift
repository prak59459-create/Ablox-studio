import Foundation

/// How much care each person in a crowd gets on screen.
///
/// Everyone still moves every frame. The nearest are posed every frame
/// too (arms and legs swinging); the rest take turns, a third of them a
/// frame, which nobody notices from far away. Only the nearest show their
/// names, and only the nearest wear their faces, hats, pets and auras.
/// With a hundred in Last Survivor Games, posing and labelling every one of
/// them every frame made the game too slow to play.
///
/// Standing in the crowd was still slow when watching from the stands was
/// not: from the stands the crowd is beyond the reach of the sun's shadows,
/// in it all hundred were drawn twice, once more for the shadows. With a
/// crowd near, shadows reach only a few steps (`shadowDistance`).
public enum CrowdDetail {

    /// The nearest this many are posed every frame.
    public static let everyFrame = 16

    /// The rest are posed once in this many frames.
    public static let turns = 3

    /// Names over heads, nearest first.
    public static let nameTags = 30

    /// The nearest this many wear their faces, hats, pets and auras; the
    /// rest are their blocky selves, a few things each to draw instead of
    /// a dozen.
    public static let dressed = 24

    /// Whether the one `rank` places from the camera is dressed.
    public static func isDressed(rank: Int) -> Bool {
        rank < dressed
    }

    /// Name tags are worked out for the nearest this many (a few more than
    /// are shown, as the order is a quarter of a second old).
    public static let nameTagCandidates = 40

    /// More people than this within the shadows' reach is a crowd.
    public static let shadowCrowd = 24

    /// How far shadows reach while a crowd is near.
    public static let crowdShadowDistance: Float = 12

    /// How far the sun's shadows reach: the graphics setting's `distance`
    /// (nil: no shadows), or less with more than `shadowCrowd` people
    /// `within` it.
    public static func shadowDistance(_ distance: Float?, peopleWithin: Int) -> Float? {
        guard let distance else { return nil }
        return peopleWithin > shadowCrowd ? Swift.min(distance, crowdShadowDistance) : distance
    }

    /// Whether the one `rank` places from the camera (0 is nearest) is
    /// posed in frame number `frame`.
    public static func poses(rank: Int, frame: Int) -> Bool {
        rank < everyFrame || (rank + frame) % turns == 0
    }

    /// Each one's place from the camera, nearest first. Ties keep the order
    /// given.
    public static func ranks<ID: Hashable>(_ distances: [(id: ID, distance: Float)]) -> [ID: Int] {
        let ordered = distances.enumerated().sorted {
            $0.element.distance != $1.element.distance ? $0.element.distance < $1.element.distance : $0.offset < $1.offset
        }
        var ranks: [ID: Int] = [:]
        for (rank, entry) in ordered.enumerated() { ranks[entry.element.id] = rank }
        return ranks
    }
}
