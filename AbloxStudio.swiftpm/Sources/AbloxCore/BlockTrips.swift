import Foundation

/// The blocks an iPad is drawing on their way somewhere (`move` / `move_to`),
/// and where each one is drawn at a moment.
///
/// The scene places them itself every frame from this, rather than handing
/// the trip to RealityKit: a character that bounces or sways has its turn and
/// size set every frame too, and new words over it change the same entity, so
/// a trip RealityKit animated could be drawn somewhere other than where the
/// script has the character — the buy button for a Meme Heist meme showed on
/// an empty carpet. Worked out here, where it is drawn is where it is.
public struct BlockTrips: Sendable {

    /// A move for a block not drawn yet: the change that makes it came in
    /// after the move did. It sets off when the block appears.
    struct Waiting: Sendable {
        var offset: Vec3
        var start: Double
        var duration: Double
    }

    public private(set) var trips: [UUID: BlockTravel] = [:]
    private var waiting: [UUID: Waiting] = [:]

    /// How long a move waits for its block to appear, past its own length.
    static let patience: Double = 5

    public init() {}

    public var isEmpty: Bool { trips.isEmpty && waiting.isEmpty }

    /// A move for block `id`, drawn at `current` (from its parent), by
    /// `offset` over `duration` seconds from `clock`. One still on its way
    /// carries on from where it has got to, to the end of that trip and the
    /// new offset on — where the host's map has it.
    public mutating func start(_ id: UUID, at current: Vec3, offset: Vec3, duration: Double, clock: Double) {
        var end = current + offset
        if let trip = trips[id], trip.end > clock { end = trip.from + trip.offset + offset }
        waiting[id] = nil
        trips[id] = BlockTravel(from: current, offset: end - current, start: clock, duration: Swift.max(duration, 0))
    }

    /// A move for a block that is not drawn yet.
    public mutating func hold(_ id: UUID, offset: Vec3, duration: Double, clock: Double) {
        waiting[id] = Waiting(offset: offset, start: clock, duration: Swift.max(duration, 0))
    }

    /// Block `id` has appeared at `position`: a move held for it sets off, as
    /// far along as it would be had the block been there all along.
    @discardableResult
    public mutating func appeared(_ id: UUID, at position: Vec3, clock: Double) -> Bool {
        guard let held = waiting.removeValue(forKey: id) else { return false }
        guard clock <= held.start + held.duration + Self.patience else { return false }
        trips[id] = BlockTravel(from: position, offset: held.offset, start: held.start, duration: held.duration)
        return true
    }

    /// The map has block `id` at `position` now. A trip stays when that is
    /// unchanged or where it set off (new words or colours on the way, or the
    /// block just drawn) or where it is going (the map catching up at the end); anywhere else, the script put
    /// the block there and the trip is over. True when the trip stays.
    @discardableResult
    public mutating func mapHas(_ id: UUID, at position: Vec3, previously: Vec3?) -> Bool {
        guard let trip = trips[id] else { return false }
        if let previously, position.distance(to: previously) < 0.001 { return true }
        for kept in [trip.from, trip.from + trip.offset] where position.distance(to: kept) < 0.001 { return true }
        trips[id] = nil
        return false
    }

    /// Where block `id` is drawn (from its parent) at `clock`, while on its way.
    public func position(of id: UUID, at clock: Double) -> Vec3? {
        trips[id]?.drawnPosition(at: clock)
    }

    /// Where every travelling block is drawn at `clock`. A trip that is over
    /// gives its end one last time and is let go.
    public mutating func advance(to clock: Double) -> [(id: UUID, position: Vec3)] {
        waiting = waiting.filter { clock <= $0.value.start + $0.value.duration + Self.patience }
        guard !trips.isEmpty else { return [] }
        var placed: [(id: UUID, position: Vec3)] = []
        placed.reserveCapacity(trips.count)
        for (id, trip) in trips { placed.append((id, trip.drawnPosition(at: clock))) }
        trips = trips.filter { $0.value.end > clock }
        return placed
    }

    public mutating func forget(_ id: UUID) {
        trips[id] = nil
        waiting[id] = nil
    }

    public mutating func removeAll() {
        trips.removeAll()
        waiting.removeAll()
    }
}

public extension BlockTravel {
    /// How far along it is drawn, from 0 to 1: long trips at a steady speed,
    /// short ones speeding up and slowing down.
    func drawnProgress(at clock: Double) -> Double {
        let t = progress(at: clock)
        guard !Self.isSteady(duration: duration) else { return t }
        return t * t * (3 - 2 * t)
    }

    /// Where it is drawn (from its parent) at `clock`.
    func drawnPosition(at clock: Double) -> Vec3 {
        from + offset * Float(drawnProgress(at: clock))
    }
}
