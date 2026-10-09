import Foundation

// Someone joining while blocks are on their way somewhere (`BlockTravel`).

public extension GameRuntime {
    /// The map for someone joining now, and the rest of each trip for them.
    ///
    /// `before` is `travels` as it was before the joiner's `on join` ran: a
    /// trip that started in there is already in the welcome, sent to everyone.
    /// A block still on its way is put where it has got to, and goes on to
    /// the end in the time left — not left standing where it will end up.
    func joiningWorld(for peer: PeerID, before: [UUID: BlockTravel]) -> (world: WorldDocument, effects: [Effect]) {
        var copy = world
        var effects: [Effect] = []
        for (id, travel) in before where travels[id] == travel && travel.end > clock {
            // Put somewhere else since (a script set its position): the map
            // already has it right.
            guard let block = copy.block(id: id), block.position == travel.from + travel.offset else { continue }
            let now = travel.position(at: clock)
            _ = copy.mutate(id: id) { $0.position = now }
            effects.append(Effect(ruleID: nil, targetPeerID: peer,
                                  action: .move(blockID: id, offset: travel.from + travel.offset - now, duration: travel.end - clock)))
        }
        return (copy, effects)
    }
}
