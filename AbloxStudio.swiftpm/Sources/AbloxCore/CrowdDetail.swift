import Foundation

/// How much care each person in a crowd gets on screen.
///
/// Everyone still moves every frame. The nearest are posed every frame
/// too (arms and legs swinging); the rest take turns, a third of them a
/// frame, which nobody notices from far away. Only the nearest show their
/// names. With a hundred in Last Survivor Games, posing and labelling every
/// one of them every frame made the game too slow to play.
public enum CrowdDetail {

    /// The nearest this many are posed every frame.
    public static let everyFrame = 16

    /// The rest are posed once in this many frames.
    public static let turns = 3

    /// Names over heads, nearest first.
    public static let nameTags = 30

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
