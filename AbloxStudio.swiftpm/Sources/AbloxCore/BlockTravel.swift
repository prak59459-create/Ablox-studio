import Foundation

/// A block on its way somewhere by `move` / `move_to` over some seconds.
///
/// The host's copy of the map takes the end position at once, and every iPad
/// animates the trip itself. So someone who joins halfway would get a map with
/// the block already at the end, and no animation to bring it there — a
/// character walking a long carpet stood still at its far end. The host keeps
/// each trip until it is over, to give a joiner the block where it is now and
/// the rest of the trip (`GameRuntime.joiningWorld`).
public struct BlockTravel: Equatable, Sendable {
    /// The block's own position (from its parent) when it set off.
    public var from: Vec3
    public var offset: Vec3
    /// The host's clock when it set off.
    public var start: Double
    public var duration: Double

    public init(from: Vec3, offset: Vec3, start: Double, duration: Double) {
        self.from = from
        self.offset = offset
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }

    /// How far along, from 0 to 1. Long trips go at a steady speed
    /// (`isSteady`), so this is also how far along the way it is.
    public func progress(at clock: Double) -> Double {
        guard duration > 0 else { return 1 }
        return Swift.min(Swift.max((clock - start) / duration, 0), 1)
    }

    /// Where the block is (from its parent) at `clock`.
    public func position(at clock: Double) -> Vec3 {
        from + offset * Float(progress(at: clock))
    }

    /// Trips this long go at a steady speed, the way scripts work out where a
    /// walker is (`start + speed × time`). Shorter ones — a door, a lift, a
    /// pop — speed up and slow down, which looks nicer and is over soon.
    public static let steadyFrom: Double = 2

    public static func isSteady(duration: Double) -> Bool {
        duration >= steadyFrom
    }

    /// The nearest block, among `id` and the blocks it hangs from, that is
    /// travelling: a character's parts are drawn where their root has got
    /// to, not where the map says the root will end up.
    public static func travellingAncestor(of id: UUID, travelling: Set<UUID>, parent: (UUID) -> UUID?) -> UUID? {
        guard !travelling.isEmpty else { return nil }
        var cursor: UUID? = id
        var steps = 0
        while let current = cursor, steps < 64 {
            if travelling.contains(current) { return current }
            cursor = parent(current)
            steps += 1
        }
        return nil
    }
}
