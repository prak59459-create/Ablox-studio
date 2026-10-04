import Foundation

// The building tools beyond move, rotate and scale: picking many parts at
// once, copying between worlds, lining parts up, repeating them in a row or
// a ring, mirroring, shaping the ground, painting, layers and locks. Every
// one is a plain edit of the document, one undo step each, tested without
// an iPad.

// MARK: - Picking

public extension EditorDocument {

    /// Parts that can be picked in the 3D view: not locked, not on a hidden
    /// or locked layer.
    func isPickable(_ block: BlockData) -> Bool {
        !block.isLocked && !hiddenLayers.contains(block.layerName) && !lockedLayers.contains(block.layerName)
    }

    /// Selects every pickable part among `ids` (a box drawn in the view).
    mutating func selectBlocks(_ ids: [UUID], additive: Bool) {
        let pickable = Set(world.blocks.filter { ids.contains($0.id) && isPickable($0) }.map(\.id))
        if additive { selection.formUnion(pickable) } else { selection = pickable }
    }

    /// Centre to centre, in metres, between the first two selected parts.
    var selectionDistance: Float? {
        let ids = selectedBlocks.map(\.id)
        guard ids.count >= 2, let a = world.worldBounds(of: ids[0]), let b = world.worldBounds(of: ids[1]) else { return nil }
        return a.center.distance(to: b.center)
    }
}

// MARK: - Copy and paste, across worlds

/// Parts copied from one world, to paste into this or another: whole
/// subtrees, positioned relative to where they were copied from.
public struct PartClipboard: Codable, Hashable, Sendable {
    public static let pasteboardType = "com.ablox.parts"

    public var blocks: [BlockData]
    /// Their images, so a picture on a part comes with it.
    public var images: [WorldImage]

    public var isEmpty: Bool { blocks.isEmpty }

    public var encoded: Data? { try? JSONEncoder().encode(self) }

    public init(blocks: [BlockData], images: [WorldImage] = []) {
        self.blocks = blocks
        self.images = images
    }

    public init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(PartClipboard.self, from: data), !decoded.blocks.isEmpty else { return nil }
        self = decoded
    }
}

public extension EditorDocument {

    /// The selection, with everything inside it, centred on the origin.
    func copySelection() -> PartClipboard? {
        let roots = topLevelSelection
        guard !roots.isEmpty, let bounds = selectionBounds else { return nil }
        var blocks: [BlockData] = []
        for root in roots {
            for var block in world.subtree(of: root.id) {
                if block.id == root.id {
                    // A root inside an unselected parent comes out on its own.
                    block.parentID = nil
                    block.position = world.worldPosition(of: block.id) - Vec3(bounds.center.x, bounds.min.y, bounds.center.z)
                }
                blocks.append(block)
            }
        }
        let pictures = Set(blocks.compactMap(\.imageID))
        return PartClipboard(blocks: blocks, images: world.images.filter { pictures.contains($0.id) })
    }

    /// Adds copied parts with `at` as the middle of their base; returns
    /// them, selected.
    @discardableResult
    mutating func paste(_ clipboard: PartClipboard, at point: Vec3) -> [UUID] {
        var images = world.images
        let made = pasteCommands(clipboard, at: point.snapped(toGridOf: gridSize), turn: 0, images: &images)
        guard !made.roots.isEmpty, world.blocks.count + clipboard.blocks.count <= GameRuntime.Limits.maximumBlocks else { return [] }
        let setImages: [EditCommand] = images != world.images ? [.setImages(before: world.images, after: images)] : []
        perform(.group(label: "Paste", commands: setImages + made.commands))
        selection = Set(made.roots)
        return made.roots
    }

    /// The inserts a paste makes, not yet performed: each root placed at
    /// `base` and turned `turn` degrees about the vertical.
    func pasteCommands(_ clipboard: PartClipboard, at base: Vec3, turn: Float,
                       images: inout [WorldImage]) -> (commands: [EditCommand], roots: [UUID]) {
        var idMap: [UUID: UUID] = [:]
        for block in clipboard.blocks { idMap[block.id] = UUID() }
        // Pictures this world does not have yet come along, while there is room.
        for picture in clipboard.images where !images.contains(where: { $0.id == picture.id }) && images.count < WorldImage.maximumCount {
            images.append(picture)
        }
        var commands: [EditCommand] = []
        var roots: [UUID] = []
        var names = Set(world.blocks.map(\.name))
        let radians = turn * .pi / 180
        for original in clipboard.blocks {
            var block = original
            block.id = idMap[original.id] ?? UUID()
            block.parentID = original.parentID.flatMap { idMap[$0] }
            if block.parentID == nil {
                let offset = original.position
                block.position = base + Vec3(offset.x * cos(radians) + offset.z * sin(radians), offset.y,
                                             -offset.x * sin(radians) + offset.z * cos(radians))
                if turn != 0 {
                    var degrees = block.rotationDegrees
                    degrees.y = normalizeDegrees(degrees.y + turn)
                    block.rotationDegrees = degrees
                }
                var name = original.name
                var number = 2
                while names.contains(name) {
                    name = original.name + " " + String(number)
                    number += 1
                }
                names.insert(name)
                block.name = name
                roots.append(block.id)
            }
            if let image = block.imageID, !images.contains(where: { $0.id == image }) { block.imageID = nil }
            block.isLocked = false
            commands.append(.insert(block))
        }
        return (commands, roots)
    }

    /// Selected parts whose parent is not selected too.
    var topLevelSelection: [BlockData] {
        let ids = selection
        return selectedBlocks.filter { block in !world.ancestors(of: block.id).contains { ids.contains($0.id) } }
    }
}

// MARK: - Lining up

public enum AlignEdge: String, CaseIterable, Sendable, Identifiable {
    case minimum, center, maximum
    public var id: String { rawValue }
}

public enum Axis3: Int, CaseIterable, Sendable, Identifiable {
    case x, y, z
    public var id: Int { rawValue }
    public var name: String { ["X", "Y", "Z"][rawValue] }
}

extension Vec3 {
    subscript(axis: Axis3) -> Float {
        get { axis == .x ? x : axis == .y ? y : z }
        set {
            switch axis {
            case .x: x = newValue
            case .y: y = newValue
            case .z: z = newValue
            }
        }
    }
}

public extension EditorDocument {

    /// Moves the selected parts so their `edge` on `axis` lines up with the
    /// selection's.
    mutating func align(_ axis: Axis3, to edge: AlignEdge) {
        guard let all = selectionBounds, selection.count > 1 else { return }
        let target: Float = edge == .minimum ? all.min[axis] : edge == .maximum ? all.max[axis] : all.center[axis]
        var moves: [UUID: Float] = [:]
        for block in topLevelSelection {
            guard let bounds = world.worldBounds(of: block.id) else { continue }
            let current: Float = edge == .minimum ? bounds.min[axis] : edge == .maximum ? bounds.max[axis] : bounds.center[axis]
            moves[block.id] = target - current
        }
        mutateSelection(label: "Align") { block in
            guard let shift = moves[block.id] else { return }
            block.position[axis] += shift
        }
    }

    /// Spaces the selected parts evenly on `axis`, first and last staying put.
    mutating func distribute(_ axis: Axis3) {
        let parts = topLevelSelection.compactMap { block in world.worldBounds(of: block.id).map { (block.id, $0.center[axis]) } }
            .sorted { $0.1 < $1.1 }
        guard parts.count > 2, let first = parts.first?.1, let last = parts.last?.1 else { return }
        let gap = (last - first) / Float(parts.count - 1)
        var moves: [UUID: Float] = [:]
        for (index, part) in parts.enumerated() { moves[part.0] = first + gap * Float(index) - part.1 }
        mutateSelection(label: "Distribute") { block in
            guard let shift = moves[block.id] else { return }
            block.position[axis] += shift
        }
    }

    // MARK: Repeating

    /// `count` more copies of the selection, each `offset` further on —
    /// one undo step.
    mutating func repeatInRow(count: Int, offset: Vec3) {
        guard let clip = copySelection(), let bounds = selectionBounds, count > 0 else { return }
        let base = Vec3(bounds.center.x, bounds.min.y, bounds.center.z)
        let copies = Swift.min(count, 200)
        guard world.blocks.count + clip.blocks.count * copies <= GameRuntime.Limits.maximumBlocks else { return }
        var images = world.images
        var commands: [EditCommand] = []
        var made = selection
        for index in 1...copies {
            let pasted = pasteCommands(clip, at: base + offset * Float(index), turn: 0, images: &images)
            commands += pasted.commands
            made.formUnion(pasted.roots)
        }
        perform(.group(label: "Repeat", commands: commands))
        selection = made
    }

    /// The selection repeated round a ring of `radius`: the original on the
    /// ring's east side and `count - 1` copies around it, each turned to
    /// match — one undo step.
    mutating func repeatInRing(count: Int, radius: Float) {
        guard let clip = copySelection(), let bounds = selectionBounds, count > 1, radius > 0 else { return }
        let copies = Swift.min(count, 200)
        guard world.blocks.count + clip.blocks.count * copies <= GameRuntime.Limits.maximumBlocks else { return }
        let center = Vec3(bounds.center.x - radius, bounds.min.y, bounds.center.z)
        var images = world.images
        var commands: [EditCommand] = []
        var made = selection
        for index in 1..<copies {
            let angle = Float(index) / Float(copies) * 360
            let radians = angle * .pi / 180
            let spot = center + Vec3(cos(radians) * radius, 0, -sin(radians) * radius)
            let pasted = pasteCommands(clip, at: spot, turn: angle, images: &images)
            commands += pasted.commands
            made.formUnion(pasted.roots)
        }
        perform(.group(label: "Ring", commands: commands))
        selection = made
    }

    /// Flips the selection across its own middle on `axis` — or, with
    /// `copy`, adds a flipped copy beside it.
    mutating func mirror(_ axis: Axis3, copy: Bool) {
        guard let bounds = selectionBounds else { return }
        if copy {
            guard let clip = copySelection() else { return }
            var base = Vec3(bounds.center.x, bounds.min.y, bounds.center.z)
            base[axis] = axis == .y ? bounds.max.y : bounds.max[axis] + bounds.size[axis] * 0.5
            let ids = paste(clip, at: base)
            guard !ids.isEmpty else { return }
            mirror(axis, copy: false)
            return
        }
        let middle = bounds.center[axis]
        let roots = Set(topLevelSelection.map(\.id))
        mutateSelection(label: "Mirror") { block in
            guard roots.contains(block.id) else { return }
            block.position[axis] = 2 * middle - block.position[axis]
            var degrees = block.rotationDegrees
            // A reflection: turns about the other axes change direction.
            switch axis {
            case .x: degrees.y = -degrees.y; degrees.z = -degrees.z
            case .y: degrees.x = -degrees.x; degrees.z = -degrees.z
            case .z: degrees.x = -degrees.x; degrees.y = -degrees.y
            }
            block.rotationDegrees = degrees
        }
    }
}

// MARK: - Painting, layers and locks

public extension EditorDocument {

    /// Paints one part (the paint tool), keeping how see-through it is.
    mutating func paint(_ id: UUID, with color: ColorRGBA) {
        guard var block = world.block(id: id), isPickable(block) else { return }
        let painted = color.withAlpha(block.color.a)
        guard block.color != painted else { return }
        let before = block
        block.color = painted
        perform(.modify(before: before, after: block))
    }

    mutating func setLocked(_ locked: Bool) {
        mutateSelection(label: locked ? "Lock" : "Unlock") { $0.isLocked = locked }
    }

    /// Puts the selection on a layer ("" for the main one).
    mutating func setLayer(_ name: String) {
        let layer = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        mutateSelection(label: "Layer") { $0.layer = layer.isEmpty ? nil : layer }
    }

    /// Every layer in use, the main one first.
    var layers: [String] {
        [""] + Set(world.blocks.compactMap(\.layer)).sorted()
    }

    /// Everything on a layer, selected (Explorer → Layers).
    mutating func selectLayer(_ name: String) {
        selection = Set(world.blocks.filter { $0.layerName == name }.map(\.id))
    }
}

public extension BlockData {
    /// The layer's name; "" is the main layer.
    var layerName: String { layer ?? "" }
}

// MARK: - The ground

/// Shaping the ground: columns of grass on a two-metre grid, raised,
/// lowered or levelled where tapped.
public enum TerrainAction: String, CaseIterable, Sendable, Identifiable {
    case raise, lower, flatten
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .raise: return L("Raise")
        case .lower: return L("Dig")
        case .flatten: return L("Flatten")
        }
    }

    public var symbolName: String {
        switch self {
        case .raise: return "arrow.up.square"
        case .lower: return "arrow.down.square"
        case .flatten: return "equal.square"
        }
    }
}

public extension EditorDocument {
    static let terrainTag = "terrain"
    static let terrainCell: Float = 2
    static let terrainStep: Float = 1

    /// The ground column at a point, if there is one.
    func terrainColumn(at point: Vec3) -> BlockData? {
        let cell = Self.terrainCell
        let x = (point.x / cell).rounded() * cell
        let z = (point.z / cell).rounded() * cell
        return world.blocks.first { $0.hasTag(Self.terrainTag) && abs($0.position.x - x) < 0.01 && abs($0.position.z - z) < 0.01 }
    }

    /// Raises, lowers or levels the ground where the finger is. A column's
    /// base stays at 0; lowering it to nothing removes it.
    mutating func shapeTerrain(_ action: TerrainAction, at point: Vec3, brush: Int = 1) {
        let cell = Self.terrainCell
        let centreX = (point.x / cell).rounded() * cell
        let centreZ = (point.z / cell).rounded() * cell
        let radius = Swift.max(0, brush - 1)
        var spots: [Vec3] = []
        for dx in -radius...radius {
            for dz in -radius...radius where dx * dx + dz * dz <= radius * radius {
                spots.append(Vec3(centreX + Float(dx) * cell, 0, centreZ + Float(dz) * cell))
            }
        }
        // Levelling goes to the height under the finger.
        let level = terrainColumn(at: point).map { $0.scale.y } ?? 0
        var commands: [EditCommand] = []
        for spot in spots {
            let existing = terrainColumn(at: spot)
            let height = existing?.scale.y ?? 0
            let next: Float
            switch action {
            case .raise: next = Swift.min(40, height + Self.terrainStep)
            case .lower: next = Swift.max(0, height - Self.terrainStep)
            case .flatten: next = level
            }
            guard next != height else { continue }
            if var column = existing {
                let before = column
                if next <= 0 {
                    commands.append(.delete(column))
                    continue
                }
                column.scale.y = next
                column.position.y = next / 2
                commands.append(.modify(before: before, after: column))
            } else if next > 0 {
                var column = BlockData(name: "Ground", shape: .box,
                                       transform: Transform3D(position: Vec3(spot.x, next / 2, spot.z), scale: Vec3(cell, next, cell)),
                                       color: ColorRGBA(hex: "#4ADE80")!, material: .grass, tags: [Self.terrainTag])
                column.layer = "Terrain"
                commands.append(.insert(column))
            }
        }
        guard !commands.isEmpty else { return }
        perform(.group(label: action.displayName, commands: commands))
    }

    /// Rolling hills over a square, from a seed (the same seed, the same hills).
    mutating func generateTerrain(size: Int, height: Float, seed: UInt64) {
        let cell = Self.terrainCell
        let half = size / 2
        var commands: [EditCommand] = []
        var random = seed == 0 ? 1 : seed
        func next() -> Float {
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            return Float(random % 10_000) / 10_000
        }
        let phases = (0..<4).map { _ in next() * 6.28 }
        for ix in -half..<half {
            for iz in -half..<half {
                let x = Float(ix), z = Float(iz)
                let wave = sin(x * 0.35 + phases[0]) + cos(z * 0.3 + phases[1]) + 0.5 * sin((x + z) * 0.6 + phases[2])
                let h = Swift.max(1, (1 + (wave + 2.5) / 5 * height).rounded())
                let spot = Vec3(x * cell, 0, z * cell)
                if let existing = terrainColumn(at: spot) { commands.append(.delete(existing)) }
                var column = BlockData(name: "Ground", shape: .box,
                                       transform: Transform3D(position: Vec3(spot.x, h / 2, spot.z), scale: Vec3(cell, h, cell)),
                                       color: h > height * 0.8 ? ColorRGBA(hex: "#A8A29E")! : ColorRGBA(hex: "#4ADE80")!,
                                       material: h > height * 0.8 ? .stone : .grass, tags: [Self.terrainTag])
                column.layer = "Terrain"
                commands.append(.insert(column))
            }
        }
        guard world.blocks.count + commands.count <= GameRuntime.Limits.maximumBlocks else { return }
        perform(.group(label: "Terrain", commands: commands))
    }
}

// MARK: - How heavy the world is

/// A quick look at what makes a world slow on an older iPad.
public struct WorldWeight: Hashable, Sendable {
    public enum Level: Int, Sendable, RankedByRawValue {
        case light, fine, heavy, tooHeavy

        public var displayName: String {
            switch self {
            case .light: return L("Light")
            case .fine: return L("Fine")
            case .heavy: return L("Heavy")
            case .tooHeavy: return L("Too heavy")
            }
        }
    }

    public var blocks: Int
    public var seeThrough: Int
    public var particleBlocks: Int
    public var lamps: Int
    public var pictureBytes: Int
    public var scriptLines: Int
    public var level: Level
    /// What to do about it, most useful first.
    public var advice: [String]

    public static func assess(_ world: WorldDocument) -> WorldWeight {
        let blocks = world.blocks.count
        let seeThrough = world.blocks.filter { $0.color.a * $0.material.alphaScale < 0.99 }.count
        let particles = world.blocks.filter { $0.particles != nil }.count
        let lamps = world.blocks.filter { $0.light != nil }.count
        let pictures = world.images.reduce(0) { $0 + $1.data.count }
        let lines = world.scripts.reduce(0) { $0 + $1.source.split(separator: "\n", omittingEmptySubsequences: false).count }

        var score = 0
        var advice: [String] = []
        if blocks > 3_000 { score += 3; advice.append(L("{} parts: over 3,000 is slow on older iPads. Join small parts into bigger ones.", blocks)) }
        else if blocks > 1_500 { score += 2; advice.append(L("{} parts: fine on newer iPads, heavy on older ones.", blocks)) }
        else if blocks > 600 { score += 1 }
        if seeThrough > 200 { score += 1; advice.append(L("{} see-through parts: glass and water cost more to draw.", seeThrough)) }
        if particles > 16 { score += 1; advice.append(L("{} parts give off particles; only the 16 nearest are shown.", particles)) }
        if lamps > BlockLight.maximumLit { advice.append(L("{} lamps; only {} light up at once.", lamps, BlockLight.maximumLit)) }
        if pictures > 2_000_000 { score += 1; advice.append(L("The pictures are large; smaller ones load faster.")) }
        if lines > 3_000 { score += 1; advice.append(L("{} lines of script. Check which handlers are heavy with Test run.", lines)) }
        let level: Level = score >= 4 ? .tooHeavy : score >= 2 ? .heavy : score >= 1 ? .fine : .light
        return WorldWeight(blocks: blocks, seeThrough: seeThrough, particleBlocks: particles, lamps: lamps,
                           pictureBytes: pictures, scriptLines: lines, level: level, advice: advice)
    }
}

// MARK: - The history, as a list

public extension EditorDocument {
    /// Steps that can be undone, newest last.
    var historySteps: [String] { history.steps }

    /// Undoes back to (and including) step `index` of `historySteps`.
    mutating func undo(toStep index: Int) {
        let count = history.steps.count - index
        guard count > 0 else { return }
        for _ in 0..<count { undo() }
    }
}
