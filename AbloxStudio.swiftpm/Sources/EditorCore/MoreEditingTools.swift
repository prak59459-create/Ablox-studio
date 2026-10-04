import Foundation

// More building tools: clearing away parts stacked on one another, swapping
// one colour for another, scattering copies about, dropping parts onto what
// is below them, naming parts in a row, varying their colours a little, and
// remembering selections and camera spots. Each is one undo step, tested
// without an iPad.

public extension EditorDocument {

    // MARK: Clean up

    /// Removes parts identical to another in the same place
    /// (`WorldCheck.duplicates`). Returns how many went.
    @discardableResult
    mutating func removeDuplicates() -> Int {
        let extras = WorldCheck.duplicates(in: world)
        guard !extras.isEmpty else { return 0 }
        let commands = extras.compactMap { world.block(id: $0) }.map { EditCommand.delete($0) }
        perform(.group(label: "Clean up", commands: commands))
        selection.subtract(extras)
        return extras.count
    }

    // MARK: Colours

    /// Every part of colour `from` (in the selection, or the whole world with
    /// nothing selected) repainted `to`, keeping how see-through each is.
    /// Returns how many changed.
    @discardableResult
    mutating func replaceColour(_ from: ColorRGBA, with to: ColorRGBA) -> Int {
        let scope = selection.isEmpty ? world.blocks : selectedBlocks
        var commands: [EditCommand] = []
        for block in scope where isPickable(block) && Self.sameColour(block.color, from) {
            var after = block
            after.color = to.withAlpha(block.color.a)
            if after != block { commands.append(.modify(before: block, after: after)) }
        }
        guard !commands.isEmpty else { return 0 }
        perform(.group(label: "Replace colour", commands: commands))
        return commands.count
    }

    /// Close enough to count as the same colour: as picked, a hex apart.
    static func sameColour(_ a: ColorRGBA, _ b: ColorRGBA) -> Bool {
        abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
    }

    /// The colours in use, most used first, for picking what to replace.
    var coloursInUse: [ColorRGBA] {
        var counts: [String: (ColorRGBA, Int)] = [:]
        for block in world.blocks {
            let key = block.color.withAlpha(1).hexString
            counts[key] = (counts[key]?.0 ?? block.color.withAlpha(1), (counts[key]?.1 ?? 0) + 1)
        }
        return counts.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.hexString < $1.0.hexString }.map(\.0)
    }

    /// Each selected part's colour a little lighter or darker, for ground,
    /// leaves or walls that look less flat. The same seed, the same result.
    mutating func varyColours(amount: Float = 0.12, seed: UInt64) {
        var random = EditingRandom(seed)
        let spread = Swift.max(0, Swift.min(0.5, amount))
        mutateSelection(label: "Vary colours") { block in
            let shade = (random.unit() * 2 - 1) * spread
            let c = block.color
            func adjust(_ v: Float) -> Float { Swift.max(0, Swift.min(1, v + shade)) }
            block.color = ColorRGBA(r: adjust(c.r), g: adjust(c.g), b: adjust(c.b), a: c.a)
        }
    }

    // MARK: Scatter

    /// `count` copies of the selection dropped at random within `radius` of
    /// it, each turned a random way — trees in a wood, rocks on a beach.
    /// One undo step; the copies end up selected.
    mutating func scatter(count: Int, radius: Float, seed: UInt64) {
        guard let clip = copySelection(), let bounds = selectionBounds, count > 0, radius > 0 else { return }
        let copies = Swift.min(count, 200)
        guard world.blocks.count + clip.blocks.count * copies <= GameRuntime.Limits.maximumBlocks else { return }
        var random = EditingRandom(seed)
        var images = world.images
        var commands: [EditCommand] = []
        var made: Set<UUID> = []
        let centre = Vec3(bounds.center.x, bounds.min.y, bounds.center.z)
        for _ in 0..<copies {
            // Evenly over the disc, not bunched in the middle.
            let distance = radius * random.unit().squareRoot()
            let angle = random.unit() * 2 * .pi
            let spot = centre + Vec3(cos(angle) * distance, 0, sin(angle) * distance)
            let turn = (random.unit() * 360).rounded()
            let pasted = pasteCommands(clip, at: spot, turn: turn, images: &images)
            commands += pasted.commands
            made.formUnion(pasted.roots)
        }
        let setImages: [EditCommand] = images != world.images ? [.setImages(before: world.images, after: images)] : []
        perform(.group(label: "Scatter", commands: setImages + commands))
        selection = made
    }

    // MARK: Drop to the ground

    /// Each selected part moved straight down until it rests on the part
    /// below it. A part with nothing below stays put.
    mutating func dropToGround() {
        let roots = topLevelSelection
        guard !roots.isEmpty else { return }
        let moving = Set(roots.flatMap { world.subtree(of: $0.id).map(\.id) })
        // What can be landed on: everything solid that is not moving.
        let others = world.blocks.filter { !moving.contains($0.id) && $0.hasCollision }
            .compactMap { block in world.worldBounds(of: block.id) }
        var drops: [UUID: Float] = [:]
        for root in roots {
            guard let bounds = world.worldBounds(of: root.id) else { continue }
            // The highest top under it; with nothing under it, it stays
            // where it is rather than falling out of the world.
            var floor: Float?
            for other in others where other.max.y <= bounds.min.y + 0.001 {
                guard other.min.x < bounds.max.x, other.max.x > bounds.min.x,
                      other.min.z < bounds.max.z, other.max.z > bounds.min.z else { continue }
                floor = Swift.max(floor ?? other.max.y, other.max.y)
            }
            guard let floor else { continue }
            let drop = floor - bounds.min.y
            if abs(drop) > 0.0001 { drops[root.id] = drop }
        }
        guard !drops.isEmpty else { return }
        mutateSelection(label: "Drop to ground") { block in
            guard let drop = drops[block.id] else { return }
            block.position.y += drop
        }
    }

    // MARK: Names

    /// The selected parts named `base 1`, `base 2`… in the order they sit
    /// along the longest side of the selection, so "Coin 1" is at one end.
    mutating func renameInOrder(_ base: String) {
        let name = String(base.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty, let bounds = selectionBounds else { return }
        let size = bounds.size
        let axis: Axis3 = size.x >= size.z ? (size.x >= size.y ? .x : .y) : (size.z >= size.y ? .z : .y)
        let ordered = topLevelSelection.sorted { a, b in
            let pa = world.worldPosition(of: a.id)[axis], pb = world.worldPosition(of: b.id)[axis]
            return pa != pb ? pa < pb : a.name < b.name
        }
        var numbers: [UUID: Int] = [:]
        for (index, block) in ordered.enumerated() { numbers[block.id] = index + 1 }
        mutateSelection(label: "Rename") { block in
            guard let number = numbers[block.id] else { return }
            block.name = name + " " + String(number)
        }
    }
}

// MARK: - Remembered selections and camera spots

/// Selections kept under a name, per world, to pick the same parts again
/// ("Coins", "Level 2"). Parts since deleted are skipped.
public struct SelectionSets: Codable, Hashable, Sendable {
    public private(set) var sets: [String: [UUID]] = [:]
    public static let maximum = 20

    public init() {}

    public var names: [String] { sets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    /// False when the name is empty, nothing is selected, or the list is full.
    @discardableResult
    public mutating func save(_ name: String, ids: Set<UUID>) -> Bool {
        let key = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !key.isEmpty, !ids.isEmpty, sets[key] != nil || sets.count < Self.maximum else { return false }
        sets[key] = ids.sorted { $0.uuidString < $1.uuidString }
        return true
    }

    public mutating func remove(_ name: String) {
        sets[name] = nil
    }

    /// The parts still in `world`.
    public func ids(_ name: String, in world: WorldDocument) -> Set<UUID> {
        let live = Set(world.blocks.map(\.id))
        return Set(sets[name] ?? []).intersection(live)
    }
}

/// Camera spots kept per world, to jump back to a place being worked on.
public struct CameraBookmarks: Codable, Hashable, Sendable {
    public struct Spot: Codable, Hashable, Sendable {
        public var target: Vec3
        public var yaw: Float
        public var pitch: Float
        public var distance: Float
        public init(target: Vec3, yaw: Float, pitch: Float, distance: Float) {
            self.target = target
            self.yaw = yaw
            self.pitch = pitch
            self.distance = distance
        }
    }

    public static let slots = 3
    public private(set) var spots: [Spot?] = Array(repeating: nil, count: slots)

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spots = (try? c.decodeIfPresent([Spot?].self, forKey: .spots)) ?? []
        spots = Array(spots.prefix(Self.slots))
        while spots.count < Self.slots { spots.append(nil) }
    }

    public mutating func save(_ spot: Spot, in slot: Int) {
        guard spots.indices.contains(slot) else { return }
        spots[slot] = spot
    }

    public func spot(_ slot: Int) -> Spot? {
        spots.indices.contains(slot) ? spots[slot] : nil
    }
}

/// A small, fast generator with a seed: the same seed, the same numbers,
/// on every iPad.
struct EditingRandom {
    private var state: UInt64

    init(_ seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// 0 ..< 1.
    mutating func unit() -> Float {
        Float(next() % 1_000_000) / 1_000_000
    }
}
