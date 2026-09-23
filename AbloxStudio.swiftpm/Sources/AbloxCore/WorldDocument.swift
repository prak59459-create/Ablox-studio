import Foundation

// MARK: - Environment

/// Per-world lighting and atmosphere. Kept small and declarative so a world
/// file stays a readable JSON document.
public struct EnvironmentSettings: Codable, Hashable, Sendable {
    public var skyTop: ColorRGBA
    public var skyBottom: ColorRGBA
    public var ambientIntensity: Float
    public var sunPitchDegrees: Float
    public var sunYawDegrees: Float
    public var gravity: Float
    /// Players falling below this height are respawned. Stops a mis-placed
    /// jump from dropping someone into an infinite void.
    public var killPlaneHeight: Float
    public var showGroundPlane: Bool
    public var groundColor: ColorRGBA

    public init(
        skyTop: ColorRGBA = ColorRGBA(hex: "#0B1026")!,
        skyBottom: ColorRGBA = ColorRGBA(hex: "#1B2A4A")!,
        ambientIntensity: Float = 0.55,
        sunPitchDegrees: Float = -45,
        sunYawDegrees: Float = 35,
        gravity: Float = -9.81,
        killPlaneHeight: Float = -50,
        showGroundPlane: Bool = true,
        groundColor: ColorRGBA = .defaultGround
    ) {
        self.skyTop = skyTop
        self.skyBottom = skyBottom
        self.ambientIntensity = ambientIntensity
        self.sunPitchDegrees = sunPitchDegrees
        self.sunYawDegrees = sunYawDegrees
        self.gravity = gravity
        self.killPlaneHeight = killPlaneHeight
        self.showGroundPlane = showGroundPlane
        self.groundColor = groundColor
    }

    public static let `default` = EnvironmentSettings()

    /// Unit vector pointing *from* the sun, for the directional light.
    public var sunDirection: Vec3 {
        Quat.euler(degrees: Vec3(sunPitchDegrees, sunYawDegrees, 0)).act(.forward)
    }
}

// MARK: - WorldDocument

/// A complete authored world: the thing Studio saves, and the thing a host
/// broadcasts to joining players.
///
/// Blocks are stored as a flat array with `parentID` links rather than a
/// nested tree. Flat storage keeps deltas cheap (`WorldDelta` can name a
/// single block by id) and makes reparenting a one-field edit instead of a
/// subtree move.
public struct WorldDocument: Codable, Hashable, Identifiable, Sendable {
    /// Bumped whenever the on-disk shape changes incompatibly.
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var name: String
    public var authorName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var environment: EnvironmentSettings
    public var blocks: [BlockData]
    public var rules: [EventRule]
    /// The world's `.absc` script files. Empty for a world run by rules alone.
    public var scripts: [ScriptFile]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = WorldDocument.currentSchemaVersion,
        name: String = "Untitled World",
        authorName: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        environment: EnvironmentSettings = .default,
        blocks: [BlockData] = [],
        rules: [EventRule] = [],
        scripts: [ScriptFile] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.name = name
        self.authorName = authorName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.environment = environment
        self.blocks = blocks
        self.rules = rules
        self.scripts = scripts
    }

    // MARK: Coding
    //
    // Written out so that every world ever saved still opens: one from before
    // scripts has no `scripts` key, and one saved by the first scripting build
    // has a single `script` string, which becomes `main.absc`.

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, authorName, createdAt, modifiedAt, environment, blocks, rules, scripts
        case legacyScript = "script"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        name = try c.decode(String.self, forKey: .name)
        authorName = try c.decode(String.self, forKey: .authorName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        environment = try c.decode(EnvironmentSettings.self, forKey: .environment)
        blocks = try c.decode([BlockData].self, forKey: .blocks)
        rules = try c.decodeIfPresent([EventRule].self, forKey: .rules) ?? []
        if let files = try c.decodeIfPresent([ScriptFile].self, forKey: .scripts) {
            scripts = files
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .legacyScript) {
            scripts = [ScriptFile(name: "main", source: legacy)]
        } else {
            scripts = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(name, forKey: .name)
        try c.encode(authorName, forKey: .authorName)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(environment, forKey: .environment)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(rules, forKey: .rules)
        // Omitted when empty, so a rules-only world's file is unchanged.
        if !scripts.isEmpty {
            try c.encode(scripts, forKey: .scripts)
        }
    }
}

// MARK: - Lookup

public extension WorldDocument {
    func block(id: UUID) -> BlockData? {
        blocks.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        blocks.firstIndex { $0.id == id }
    }

    /// Direct children of `parent` (or the top level when `parent` is nil),
    /// in document order.
    func children(of parent: UUID?) -> [BlockData] {
        blocks.filter { $0.parentID == parent }
    }

    var rootBlocks: [BlockData] { children(of: nil) }

    /// Walks up the parent chain. Returns ancestors nearest-first.
    func ancestors(of id: UUID) -> [BlockData] {
        var result: [BlockData] = []
        var seen: Set<UUID> = [id]
        var cursor = block(id: id)?.parentID
        while let current = cursor, let parent = block(id: current) {
            // A malformed document could contain a parent cycle; stop rather
            // than spin forever.
            guard seen.insert(current).inserted else { break }
            result.append(parent)
            cursor = parent.parentID
        }
        return result
    }

    /// `id` plus every descendant, parents before children.
    func subtree(of id: UUID) -> [BlockData] {
        guard let root = block(id: id) else { return [] }
        var result = [root]
        var queue = [id]
        var seen: Set<UUID> = [id]
        while let current = queue.popLast() {
            for child in children(of: current) where seen.insert(child.id).inserted {
                result.append(child)
                queue.append(child.id)
            }
        }
        return result
    }

    /// True when `candidate` is `id` itself or sits underneath it. Guards the
    /// Explorer's drag-to-reparent against creating a cycle.
    func isDescendant(_ candidate: UUID, ofOrEqualTo id: UUID) -> Bool {
        if candidate == id { return true }
        return ancestors(of: candidate).contains { $0.id == id }
    }

    /// Accumulated world transform, composing every ancestor.
    func worldTransform(of id: UUID) -> Transform3D {
        guard let block = block(id: id) else { return .identity }
        var result = block.transform
        for ancestor in ancestors(of: id) {
            result = result.concatenating(parent: ancestor.transform)
        }
        return result
    }

    func worldPosition(of id: UUID) -> Vec3 {
        worldTransform(of: id).position
    }

    /// World-space AABB of a single block, ignoring rotation of the block
    /// itself (the box is grown to cover the rotated extents).
    func worldBounds(of id: UUID) -> BoundingBox? {
        guard let block = block(id: id) else { return nil }
        let t = worldTransform(of: id)
        let half = block.shape.unitBounds.size * t.scale * 0.5

        // Project the rotated half-extents onto the world axes so the AABB
        // still encloses a tilted block.
        let axes = [
            t.rotation.act(Vec3(half.x, 0, 0)),
            t.rotation.act(Vec3(0, half.y, 0)),
            t.rotation.act(Vec3(0, 0, half.z))
        ]
        let extent = Vec3(
            abs(axes[0].x) + abs(axes[1].x) + abs(axes[2].x),
            abs(axes[0].y) + abs(axes[1].y) + abs(axes[2].y),
            abs(axes[0].z) + abs(axes[1].z) + abs(axes[2].z)
        )
        return BoundingBox(center: t.position, size: extent * 2)
    }

    var worldBounds: BoundingBox? {
        BoundingBox.containing(blocks.compactMap { worldBounds(of: $0.id) })
    }

    // MARK: Spawning

    var spawnBlocks: [BlockData] {
        blocks.filter { $0.behavior == .spawn }
    }

    /// Where player number `index` starts. Spawn blocks are used in document
    /// order and cycled; with none authored, players start above the origin.
    func spawnPosition(forPlayerIndex index: Int) -> Vec3 {
        let spawns = spawnBlocks
        guard !spawns.isEmpty else { return Vec3(0, 2, 0) }
        let spawn = spawns[index % spawns.count]
        let t = worldTransform(of: spawn.id)
        let topOfBlock = t.position.y + (spawn.shape.unitBounds.size.y * t.scale.y) * 0.5
        return Vec3(t.position.x, topOfBlock + 1.0, t.position.z)
    }

    // MARK: Queries used by the runtime

    func blocks(taggedWith tag: String) -> [BlockData] {
        blocks.filter { $0.hasTag(tag) }
    }

    var touchSensitiveBlocks: [BlockData] {
        blocks.filter { $0.behavior.needsTouchDetection }
    }
}

// MARK: - Mutation

public extension WorldDocument {
    /// Inserts a block, keeping `modifiedAt` honest.
    mutating func insert(_ block: BlockData) {
        blocks.append(block)
        modifiedAt = Date()
    }

    /// Replaces a block in place. No-op when the id is unknown, so a delta
    /// that races a delete does not resurrect the block.
    @discardableResult
    mutating func update(_ block: BlockData) -> Bool {
        guard let i = index(of: block.id) else { return false }
        blocks[i] = block
        modifiedAt = Date()
        return true
    }

    /// Applies an edit to one block.
    @discardableResult
    mutating func mutate(id: UUID, _ body: (inout BlockData) -> Void) -> Bool {
        guard let i = index(of: id) else { return false }
        body(&blocks[i])
        modifiedAt = Date()
        return true
    }

    /// Removes a block **and its whole subtree** — orphaned children would
    /// otherwise render at world origin.
    @discardableResult
    mutating func remove(id: UUID) -> [BlockData] {
        let doomed = subtree(of: id)
        guard !doomed.isEmpty else { return [] }
        let ids = Set(doomed.map(\.id))
        blocks.removeAll { ids.contains($0.id) }
        rules.removeAll { $0.references(anyOf: ids) }
        modifiedAt = Date()
        return doomed
    }

    /// Reparents a block, rejecting moves that would create a cycle.
    @discardableResult
    mutating func setParent(of id: UUID, to newParent: UUID?) -> Bool {
        guard index(of: id) != nil else { return false }
        if let newParent {
            guard block(id: newParent) != nil else { return false }
            guard !isDescendant(newParent, ofOrEqualTo: id) else { return false }
        }
        return mutate(id: id) { $0.parentID = newParent }
    }

    /// A name that does not collide with an existing sibling, e.g. `Block 2`.
    func uniqueName(basedOn base: String) -> String {
        let existing = Set(blocks.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - Validation

public extension WorldDocument {
    struct ValidationIssue: Hashable, Sendable {
        public enum Kind: String, Sendable {
            case danglingParent
            case parentCycle
            case danglingRuleTarget
            case degenerateScale
            case noSpawnPoint
        }

        public let kind: Kind
        public let blockID: UUID?
        public let message: String

        public init(kind: Kind, blockID: UUID?, message: String) {
            self.kind = kind
            self.blockID = blockID
            self.message = message
        }
    }

    /// Structural problems worth surfacing before publishing a world. Called
    /// by Studio's "Validate" action and before a host starts a session.
    func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let ids = Set(blocks.map(\.id))

        for block in blocks {
            if let parent = block.parentID, !ids.contains(parent) {
                issues.append(.init(
                    kind: .danglingParent,
                    blockID: block.id,
                    message: L("{} points at a parent that no longer exists.", block.name)
                ))
            }
            if block.scale.x == 0 || block.scale.y == 0 || block.scale.z == 0 {
                issues.append(.init(
                    kind: .degenerateScale,
                    blockID: block.id,
                    message: L("{} has a zero scale component and will be invisible.", block.name)
                ))
            }
            // ancestors() stops at a cycle, so a block that never reaches the
            // root is the signal.
            var cursor = block.parentID
            var hops = 0
            var cycled = false
            var seen: Set<UUID> = [block.id]
            while let current = cursor {
                if !seen.insert(current).inserted { cycled = true; break }
                hops += 1
                if hops > blocks.count { cycled = true; break }
                cursor = self.block(id: current)?.parentID
            }
            if cycled {
                issues.append(.init(
                    kind: .parentCycle,
                    blockID: block.id,
                    message: L("{} is part of a parent cycle.", block.name)
                ))
            }
        }

        for rule in rules {
            for target in rule.referencedBlockIDs where !ids.contains(target) {
                issues.append(.init(
                    kind: .danglingRuleTarget,
                    blockID: target,
                    message: L("Rule “{}” refers to a block that no longer exists.", rule.name)
                ))
            }
        }

        if spawnBlocks.isEmpty {
            issues.append(.init(
                kind: .noSpawnPoint,
                blockID: nil,
                message: L("No spawn point — players will start above the origin.")
            ))
        }

        return issues
    }
}

// MARK: - Serialization

public extension WorldDocument {
    /// Encoder used for saved `.ablox` files: readable and diff-friendly.
    static func makeFileEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Encoder used on the wire: compact, but still key-sorted so identical
    /// worlds hash identically (the host compares digests to skip resends).
    static func makeWireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func encodedForFile() throws -> Data {
        try Self.makeFileEncoder().encode(self)
    }

    func encodedForWire() throws -> Data {
        try Self.makeWireEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> WorldDocument {
        let world = try makeDecoder().decode(WorldDocument.self, from: data)
        guard world.schemaVersion <= currentSchemaVersion else {
            throw WorldDocumentError.unsupportedSchema(found: world.schemaVersion, supported: currentSchemaVersion)
        }
        return world
    }
}

public enum WorldDocumentError: Error, LocalizedError, Sendable {
    case unsupportedSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(found, supported):
            return "This world was made with a newer version of Ablox (format \(found); this build understands up to \(supported))."
        }
    }
}

// MARK: - Sample content

public extension WorldDocument {
    /// The starter world a new Studio project opens with: a floor, a spawn
    /// pad, a small obstacle course and one rule, so the first tap on Play
    /// already does something.
    static func starter(named name: String = "My First World", author: String = "") -> WorldDocument {
        var world = WorldDocument(name: name, authorName: author)

        var floor = BlockData(
            name: "Floor",
            shape: .box,
            transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(40, 1, 40)),
            color: ColorRGBA(hex: "#37474F")!,
            material: .matte
        )
        floor.tags = ["ground"]
        world.blocks.append(floor)

        world.blocks.append(BlockData.preset(.spawn, at: Vec3(0, 0.1, 8)))

        // A short staircase leading to a goal.
        for step in 0..<5 {
            let height = Float(step) * 0.6 + 0.3
            var block = BlockData.preset(.block, at: Vec3(0, height * 0.5, Float(step) * -2.5))
            block.name = "Step \(step + 1)"
            block.scale = Vec3(4, height, 2)
            block.color = ColorRGBA.lerp(
                ColorRGBA(hex: "#22D3EE")!,
                ColorRGBA(hex: "#A855F7")!,
                Float(step) / 4
            )
            world.blocks.append(block)
        }

        var orb = BlockData.preset(.orb, at: Vec3(0, 3.5, -6))
        orb.name = "Coin"
        orb.tags = ["coin"]
        world.blocks.append(orb)

        world.blocks.append(BlockData.preset(.hazard, at: Vec3(6, 0.2, 0)))

        var goal = BlockData.preset(.goal, at: Vec3(0, 3.5, -13))
        goal.name = "Finish"
        world.blocks.append(goal)

        world.rules = [
            EventRule(
                name: "Coin sparkle",
                trigger: .tagTouched(tag: "coin"),
                actions: [
                    .announce(message: "+10!", duration: 1.5),
                    .playSound(name: "collect")
                ]
            )
        ]

        return world
    }

    /// An empty world with just a floor — the "Blank" template.
    static func blank(named name: String = "Blank World", author: String = "") -> WorldDocument {
        var world = WorldDocument(name: name, authorName: author)
        world.blocks = [
            BlockData(
                name: "Floor",
                shape: .box,
                transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(40, 1, 40)),
                color: ColorRGBA(hex: "#37474F")!,
                material: .matte,
                tags: ["ground"]
            ),
            BlockData.preset(.spawn, at: Vec3(0, 0.1, 0))
        ]
        return world
    }
}
