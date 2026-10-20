import Foundation

/// Who to start drawing this frame, when many arrive at once.
///
/// A game can bring in a hundred NPCs in one go (Last Survivor Games fills
/// its show to 100). Building every avatar in the same frame froze the iPad,
/// so the viewport draws a few each frame: people first, then NPCs, each in
/// the order the roster has them. A hundred are all there in under half a
/// second.
public enum RosterArrivals {

    /// Avatars started in one frame.
    public static let perFrame = 4

    /// Up to `limit` of `roster` that are not drawn yet, leaving out `local`
    /// (drawn on its own).
    public static func toDraw(_ roster: [PlayerSnapshot], except local: PeerID, limit: Int = perFrame,
                              isDrawn: (PeerID) -> Bool) -> [PlayerSnapshot] {
        guard limit > 0 else { return [] }
        let waiting = roster.filter { $0.peerID != local && !isDrawn($0.peerID) }
        let people = waiting.filter { !$0.isNPC }
        let npcs = waiting.filter(\.isNPC)
        return Array((people + npcs).prefix(limit))
    }
}
