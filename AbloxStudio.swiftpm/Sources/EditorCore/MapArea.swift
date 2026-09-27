import Foundation

/// A piece of a world to build again with an assistant: the ground under
/// the selected parts. The rest of the world stays as it is.
public struct MapArea: Equatable, Sendable {
    public var minX: Float
    public var maxX: Float
    public var minZ: Float
    public var maxZ: Float
    /// Where its ground is.
    public var floor: Float

    /// Narrower than this is too small to build anything in.
    public static let minimumSide: Float = 4

    public init(minX: Float, maxX: Float, minZ: Float, maxZ: Float, floor: Float) {
        self.minX = minX
        self.maxX = maxX
        self.minZ = minZ
        self.maxZ = maxZ
        self.floor = floor
    }

    public var width: Float { maxX - minX }
    public var depth: Float { maxZ - minZ }

    /// Whether a point is over the area (height does not matter).
    public func contains(_ point: Vec3, margin: Float = 0.01) -> Bool {
        point.x >= minX - margin && point.x <= maxX + margin && point.z >= minZ - margin && point.z <= maxZ + margin
    }
}

/// What remaking an area did.
public struct MapAreaResult: Equatable, Sendable {
    public var added = 0
    public var removed = 0
    /// Parts the assistant put outside the area, which were left out.
    public var leftOut = 0
    public var problems: [MapPlanProblem] = []

    public init(problems: [MapPlanProblem] = []) {
        self.problems = problems
    }

    public var didChange: Bool { added > 0 }
}

extension EditorDocument {

    /// The ground under the selection, at least `MapArea.minimumSide` across.
    public var selectedArea: MapArea? {
        let boxes = topLevelSelection.compactMap { world.worldBounds(of: $0.id) }
        guard let first = boxes.first else { return nil }
        var area = MapArea(minX: first.min.x, maxX: first.max.x, minZ: first.min.z, maxZ: first.max.z, floor: first.min.y)
        for box in boxes.dropFirst() {
            area.minX = Swift.min(area.minX, box.min.x)
            area.maxX = Swift.max(area.maxX, box.max.x)
            area.minZ = Swift.min(area.minZ, box.min.z)
            area.maxZ = Swift.max(area.maxZ, box.max.z)
            area.floor = Swift.min(area.floor, box.min.y)
        }
        let grow = { (low: inout Float, high: inout Float) in
            let missing = MapArea.minimumSide - (high - low)
            if missing > 0 {
                low -= missing / 2
                high += missing / 2
            }
        }
        grow(&area.minX, &area.maxX)
        grow(&area.minZ, &area.maxZ)
        return area
    }

    /// Parts just outside the area that stay, so the new piece can join up
    /// with them — nearest first.
    public func parts(around area: MapArea, margin: Float = 6, limit: Int = 24) -> [BlockData] {
        let selected = selection
        let middle = Vec3((area.minX + area.maxX) / 2, area.floor, (area.minZ + area.maxZ) / 2)
        return world.blocks
            .filter { !selected.contains($0.id) && $0.parentID == nil }
            .filter { area.contains($0.position, margin: margin) }
            .sorted { ($0.position - middle).length < ($1.position - middle).length }
            .prefix(limit)
            .map { $0 }
    }

    /// Puts the plan's parts in place of the selected ones, as one undo step.
    /// Parts the plan put outside the area are left out and counted; a start
    /// point is only kept when one was among the parts being replaced.
    public mutating func remakeSelection(with plan: MapPlan, in area: MapArea) -> MapAreaResult {
        var result = MapAreaResult()
        let built = plan.build(named: "Area")
        let spawnFiller = L("No spawn point was given, so one was added at the centre.")
        result.problems = built.problems.filter { $0.message != spawnFiller }
        guard let made = built.world else { return result }

        let replaced = topLevelSelection
        let hadSpawn = replaced.contains { block in world.subtree(of: block.id).contains { $0.behavior == .spawn } }
        let planHasSpawn = plan.parts.contains { $0.behavior?.lowercased() == BlockBehavior.spawn.rawValue }
        var kept: [BlockData] = []
        for block in made.blocks {
            if block.behavior == .spawn, !(hadSpawn && planHasSpawn) { continue }
            if area.contains(block.position, margin: 0.5) {
                kept.append(block)
            } else {
                result.leftOut += 1
            }
        }
        guard !kept.isEmpty else {
            if result.problems.isEmpty {
                result.problems.append(MapPlanProblem(message: L("None of the parts were inside the area.")))
            }
            return result
        }

        let removals = replaced.flatMap { block in world.subtree(of: block.id).reversed().map { EditCommand.delete($0) } }
        guard world.blocks.count - removals.count + kept.count <= GameRuntime.Limits.maximumBlocks else {
            result.problems.append(MapPlanProblem(message: L("That would make the world too big.")))
            return result
        }
        perform(.group(label: "Remake area", commands: removals + kept.map { EditCommand.insert($0) }))
        selection = Set(kept.map(\.id))
        result.added = kept.count
        result.removed = removals.count
        return result
    }
}

extension MapPrompt {

    /// The prompt for building one area of a world that already exists.
    public static func text(for request: Request, area: MapArea, around neighbours: [BlockData],
                            movement: MovementConfig = .default) -> String {
        func number(_ value: Float) -> String { String(format: "%.1f", Double(value)) }
        var lines = [text(for: request, movement: movement), ""]
        lines.append(L("## Only this area"))
        lines.append("")
        lines.append(L("This is one piece of a world that already exists. Build only the area from x = {} to {} and z = {} to {}. Its ground is at y = {}.",
                       number(area.minX), number(area.maxX), number(area.minZ), number(area.maxZ), number(area.floor)))
        lines.append(L("Every part's x and z must be inside that area. Use the world's own coordinates, not ones starting from 0."))
        lines.append(L("This comes before anything above about the size of the level or a start and a goal: leave out the spawn point, and fit about {} parts into the area.",
                       Swift.min(request.size.partCount, Swift.max(6, Int(area.width * area.depth / 6)))))
        if !neighbours.isEmpty {
            lines.append("")
            lines.append(L("These parts are just outside it and stay. Join up with them:"))
            for block in neighbours {
                let at = block.position, size = block.scale
                lines.append("- \(block.name): x \(number(at.x)), y \(number(at.y)), z \(number(at.z)), " +
                             "size \(number(size.x)) × \(number(size.y)) × \(number(size.z))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
