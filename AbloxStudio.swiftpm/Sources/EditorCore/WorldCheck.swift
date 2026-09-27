import Foundation

/// Mistakes a world can have that nobody sees until someone plays it: no
/// place to start, a start below the fall limit, parts stacked exactly on
/// one another, a script asking for a part by a name no part has. Each with
/// the parts involved, so the list can select them.
///
/// Run from the "…" menu (World check) and before publishing. Separate from
/// `WorldWeight`, which is about speed, not mistakes.
public struct WorldCheck: Hashable, Sendable {

    public struct Finding: Hashable, Sendable, Identifiable {
        public enum Level: Int, Comparable, Sendable {
            case note, warning, problem
            public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        }

        public let id: String
        public let level: Level
        public let message: String
        /// Parts to select when the finding is tapped.
        public let blocks: [UUID]
    }

    public let findings: [Finding]

    public var worst: Finding.Level? { findings.map(\.level).max() }
    public var isClean: Bool { findings.isEmpty }
    public var problems: Int { findings.filter { $0.level == .problem }.count }

    public static func run(_ world: WorldDocument) -> WorldCheck {
        var findings: [Finding] = []
        let killHeight = world.environment.killPlaneHeight

        // Where players start.
        let spawns = world.spawnBlocks
        if spawns.isEmpty {
            findings.append(Finding(id: "no-spawn", level: .warning,
                                    message: L("No spawn point: players start in the middle of the world. Add one from Parts."),
                                    blocks: []))
        }
        let sunk = spawns.filter { world.spawnPosition(for: $0).y < killHeight }
        if !sunk.isEmpty {
            findings.append(Finding(id: "spawn-below", level: .problem,
                                    message: L("{} spawn points are below the fall limit: players there would fall for ever.", sunk.count),
                                    blocks: sunk.map(\.id)))
        }
        if spawns.isEmpty == false, world.blocks.contains(where: { $0.behavior == .goal }) == false,
           world.blocks.contains(where: { $0.behavior == .checkpoint }) {
            findings.append(Finding(id: "no-goal", level: .note,
                                    message: L("There are checkpoints but no goal. Is there a finish?"),
                                    blocks: []))
        }

        // Out of reach below the fall limit.
        let below = world.blocks.filter { block in
            guard block.parentID == nil, let bounds = world.worldBounds(of: block.id) else { return false }
            return bounds.max.y < killHeight
        }
        if !below.isEmpty {
            findings.append(Finding(id: "below", level: .note,
                                    message: L("{} parts are below the fall limit, where nobody can reach them.", below.count),
                                    blocks: below.map(\.id)))
        }

        // Stacked exactly on one another.
        let doubles = duplicates(in: world)
        if !doubles.isEmpty {
            findings.append(Finding(id: "doubles", level: .warning,
                                    message: L("{} parts sit exactly on top of an identical part. Clean up removes the extras.", doubles.count),
                                    blocks: doubles))
        }

        // Too small to tap.
        let tiny = world.blocks.filter { block in
            let s = block.scale
            return Swift.min(s.x, s.y, s.z) < 0.05
        }
        if !tiny.isEmpty {
            findings.append(Finding(id: "tiny", level: .note,
                                    message: L("{} parts are thinner than 5 cm and hard to tap.", tiny.count),
                                    blocks: tiny.map(\.id)))
        }

        // Scripts asking for parts by name.
        let named = Dictionary(grouping: world.blocks, by: { $0.name.lowercased() })
        for name in referencedNames(in: world.scripts) {
            let matches = named[name.lowercased()] ?? []
            if matches.isEmpty {
                findings.append(Finding(id: "missing-" + name, level: .problem,
                                        message: L("A script asks for the part “{}”, but no part has that name.", name),
                                        blocks: []))
            } else if matches.count > 1 {
                findings.append(Finding(id: "twice-" + name, level: .warning,
                                        message: L("{} parts are named “{}”; a script asking for it only finds the first.", matches.count, name),
                                        blocks: matches.map(\.id)))
            }
        }

        let scriptErrors = GameRuntime.check(world.scripts).count
        if scriptErrors > 0 {
            findings.append(Finding(id: "scripts", level: .problem,
                                    message: L("The scripts have {} problems. Open Scripts and tap Check.", scriptErrors),
                                    blocks: []))
        }
        let empty = world.scripts.filter { $0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !empty.isEmpty {
            findings.append(Finding(id: "empty-scripts", level: .note,
                                    message: L("{} script files are empty.", empty.count),
                                    blocks: []))
        }

        return WorldCheck(findings: findings.sorted { $0.level > $1.level })
    }

    /// Parts identical in shape, place, turn, size and look to an earlier
    /// part with the same parent — the later ones, which could go.
    public static func duplicates(in world: WorldDocument) -> [UUID] {
        struct Key: Hashable {
            let parent: UUID?
            let shape: BlockShape
            let transform: Transform3D
            let color: ColorRGBA
            let material: MaterialKind
            let behavior: BlockBehavior
        }
        var seen = Set<Key>()
        var extras: [UUID] = []
        // Only parts without children: removing a group would take more
        // than the part itself.
        let parents = Set(world.blocks.compactMap(\.parentID))
        for block in world.blocks where !parents.contains(block.id) {
            let key = Key(parent: block.parentID, shape: block.shape, transform: block.transform,
                          color: block.color, material: block.material, behavior: block.behavior)
            if !seen.insert(key).inserted { extras.append(block.id) }
        }
        return extras
    }

    /// Names in `block("…")` calls, in the order first used.
    public static func referencedNames(in scripts: [ScriptFile]) -> [String] {
        var names: [String] = []
        for file in scripts {
            for line in file.source.components(separatedBy: "\n") {
                let code = ScriptLineTools.withoutComment(line)
                var rest = Substring(code)
                while let call = rest.range(of: "block(") {
                    // Not part of a longer name such as create_block(.
                    let before = rest[..<call.lowerBound].last
                    rest = rest[call.upperBound...]
                    if let before, before.isLetter || before.isNumber || before == "_" { continue }
                    let trimmed = rest.drop { $0 == " " }
                    guard let quote = trimmed.first, let closers = ScriptLexer.closingQuotes(for: quote) else { continue }
                    let body = trimmed.dropFirst()
                    guard let end = body.firstIndex(where: { closers.contains($0) }) else { continue }
                    let name = String(body[..<end])
                    if !name.isEmpty, !names.contains(name) { names.append(name) }
                }
            }
        }
        return names
    }
}

extension WorldDocument {
    /// Where a player appears on this spawn part.
    func spawnPosition(for spawn: BlockData) -> Vec3 {
        let t = worldTransform(of: spawn.id)
        let top = t.position.y + spawn.shape.unitBounds.size.y * t.scale.y * 0.5
        return Vec3(t.position.x, top + 1, t.position.z)
    }
}

// MARK: - What is in a world

/// Counts for the statistics sheet: what the world is made of.
public struct WorldStatistics: Hashable, Sendable {
    public struct Count: Hashable, Sendable, Identifiable {
        public let name: String
        public let count: Int
        public var id: String { name }
    }

    public let parts: Int
    public let groups: Int
    public let shapes: [Count]
    public let materials: [Count]
    public let behaviours: [Count]
    /// The most used colours, as hex, most first.
    public let colours: [Count]
    /// Width, height and depth of everything, in metres.
    public let size: Vec3
    public let scriptFiles: Int
    public let scriptLines: Int
    public let pictures: Int

    public static func of(_ world: WorldDocument, topColours: Int = 8) -> WorldStatistics {
        func counted<T: Hashable>(_ values: [T], name: (T) -> String) -> [Count] {
            Dictionary(grouping: values, by: { $0 }).map { Count(name: name($0.key), count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        }
        let blocks = world.blocks
        return WorldStatistics(
            parts: blocks.count,
            groups: Set(blocks.compactMap(\.parentID)).count,
            shapes: counted(blocks.map(\.shape)) { $0.displayName },
            materials: counted(blocks.map(\.material)) { $0.displayName },
            behaviours: counted(blocks.map(\.behavior).filter { $0 != .none }) { $0.displayName },
            colours: Array(counted(blocks.map { $0.color.withAlpha(1).hexString }) { $0 }.prefix(topColours)),
            size: world.worldBounds?.size ?? .zero,
            scriptFiles: world.scripts.count,
            scriptLines: world.scripts.reduce(0) { $0 + $1.source.split(separator: "\n", omittingEmptySubsequences: false).count },
            pictures: world.images.count
        )
    }
}
