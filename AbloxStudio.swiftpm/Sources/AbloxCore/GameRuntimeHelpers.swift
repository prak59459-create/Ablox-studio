import Foundation

// Finding people and blocks near a place, and players by team, by score or
// by chance: the searches nearly every game wrote for itself with a loop
// over players(). Listed in the reference under "Handy extras".
extension GameRuntime {

    public static let helperAPINames: [String] = [
        "nearest_player", "players_near", "random_player", "team_players", "ranking", "alive_players",
        "nearest_block", "blocks_near"
    ]

    func installHelperAPI(on interpreter: ScriptInterpreter) {
        /// The closest player still in the game, or nil; not counting the
        /// one asked about. An optional second value is how far to look.
        interpreter.define("nearest_player") { [unowned self] arguments, line in
            let from = try self.origin(arguments, line: line)
            let limit = arguments.count > 1 ? try self.number(arguments[1], "nearest_player", line) : .infinity
            return self.people(near: from, within: limit).first.map { self.object(for: $0) } ?? .null
        }
        /// Players within a distance, nearest first.
        interpreter.define("players_near") { [unowned self] arguments, line in
            let from = try self.origin(arguments, line: line)
            let radius = try self.number(arguments.count > 1 ? arguments[1] : .null, "players_near", line)
            return .list(ScriptList(self.people(near: from, within: radius).map { self.object(for: $0) }))
        }
        interpreter.define("random_player") { [unowned self, unowned interpreter] _, _ in
            let people = self.orderedStates.filter { !$0.isNPC }
            guard !people.isEmpty else { return .null }
            return self.object(for: people[interpreter.random.integer(0, people.count - 1)])
        }
        interpreter.define("team_players") { [unowned self] arguments, _ in
            let team = (arguments.first ?? .null).displayText
            return .list(ScriptList(self.orderedStates.filter { !$0.isNPC && $0.team == team }.map { self.object(for: $0) }))
        }
        /// Players by score, highest first; equal scores in the order they
        /// joined.
        interpreter.define("ranking") { [unowned self] _, _ in
            var found: [Found] = []
            for state in self.orderedStates where !state.isNPC {
                found.append(Found(state: state, order: state.joinOrder, key: -Double(self.snapshot(of: state)?.score ?? 0)))
            }
            return .list(ScriptList(Found.sorted(found).compactMap(\.state).map { self.object(for: $0) }))
        }
        /// Players not knocked out — who is left in a last-one-standing game.
        interpreter.define("alive_players") { [unowned self] _, _ in
            .list(ScriptList(self.orderedStates.filter { !$0.isNPC && $0.isAlive }.map { self.object(for: $0) }))
        }
        /// The closest block, with a tag if one is given, or nil.
        interpreter.define("nearest_block") { [unowned self] arguments, line in
            let from = try self.origin(arguments, line: line)
            let tag = arguments.count > 1 && !arguments[1].isNull ? arguments[1].displayText : nil
            return self.blocks(near: from, within: .infinity, tag: tag).first.map { self.blockObject($0) } ?? .null
        }
        /// Blocks within a distance, nearest first, with a tag if one is given.
        interpreter.define("blocks_near") { [unowned self, unowned interpreter] arguments, line in
            let from = try self.origin(arguments, line: line)
            let radius = try self.number(arguments.count > 1 ? arguments[1] : .null, "blocks_near", line)
            let tag = arguments.count > 2 && !arguments[2].isNull ? arguments[2].displayText : nil
            let found = self.blocks(near: from, within: radius, tag: tag)
            try interpreter.checkSize(found.count, line: line)
            return .list(ScriptList(found.map { self.blockObject($0) }))
        }
    }

    /// Something found, with what it is sorted by: smallest key first, then
    /// the order it was made or joined in, so every run agrees.
    private struct Found {
        var state: PlayerState?
        var block: UUID?
        var order: Int
        var key: Double

        init(state: PlayerState? = nil, block: UUID? = nil, order: Int, key: Double) {
            self.state = state
            self.block = block
            self.order = order
            self.key = key
        }

        static func sorted(_ found: [Found]) -> [Found] {
            found.sorted { (a: Found, b: Found) -> Bool in
                if a.key != b.key { return a.key < b.key }
                return a.order < b.order
            }
        }
    }

    /// Where a search starts, and what it started from, so that is left out.
    private struct SearchOrigin {
        var point: Vec3
        var person: PeerID?
        var block: UUID?
    }

    private func origin(_ arguments: [ScriptValue], line: Int) throws -> SearchOrigin {
        let value = arguments.first ?? .null
        let point = try self.point(value, line: line)
        guard case let .object(object) = value else { return SearchOrigin(point: point) }
        return SearchOrigin(point: point, person: character(object)?.peer, block: blockID(object))
    }

    /// Players in the game within `radius`, nearest first; equal distances
    /// in the order they joined, so every run agrees.
    private func people(near origin: SearchOrigin, within radius: Double) -> [PlayerState] {
        var found: [Found] = []
        for state in orderedStates where !state.isNPC && state.isAlive && state.peer != origin.person {
            guard let position = position(of: state) else { continue }
            let distance = Double(position.distance(to: origin.point))
            if distance <= radius { found.append(Found(state: state, order: state.joinOrder, key: distance)) }
        }
        return Found.sorted(found).compactMap(\.state)
    }

    private func blocks(near origin: SearchOrigin, within radius: Double, tag: String?) -> [UUID] {
        let index = worldIndex
        var found: [Found] = []
        func consider(_ id: UUID, at position: Vec3, order: Int) {
            guard id != origin.block else { return }
            let distance = Double(position.distance(to: origin.point))
            if distance <= radius { found.append(Found(block: id, order: order, key: distance)) }
        }
        if let tag {
            for id in blockLookup.blocks(taggedWith: tag) {
                let entry = index.entry(for: id)
                consider(id, at: entry?.position ?? world.worldPosition(of: id), order: entry?.order ?? 0)
            }
        } else {
            for entry in index.entries { consider(entry.id, at: entry.position, order: entry.order) }
        }
        return Found.sorted(found).compactMap(\.block)
    }
}
