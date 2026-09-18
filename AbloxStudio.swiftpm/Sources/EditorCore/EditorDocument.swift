import Foundation

/// The editor's model: a world, a selection, a tool, and an undo history.
///
/// Portable on purpose — no SwiftUI, no RealityKit. Every editing operation a
/// user can perform goes through here, which means every one of them is
/// directly unit-testable without a device, and the SwiftUI layer above is
/// left with nothing but presentation.
public struct EditorDocument: Sendable {

    public enum Tool: String, CaseIterable, Sendable, Identifiable {
        case select
        case move
        case rotate
        case scale

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .select: return "Select"
            case .move: return "Move"
            case .rotate: return "Rotate"
            case .scale: return "Scale"
            }
        }

        public var symbolName: String {
            switch self {
            case .select: return "cursorarrow"
            case .move: return "move.3d"
            case .rotate: return "rotate.3d"
            case .scale: return "scale.3d"
            }
        }
    }

    // MARK: State

    public private(set) var world: WorldDocument
    public private(set) var history = EditHistory()

    public var tool: Tool = .select
    public var selection: Set<UUID> = []

    /// Grid step in metres. `0` means snapping is off, which keeps it one
    /// value rather than a value plus a flag.
    public var gridSize: Float = 0.5
    /// Rotation snap in degrees.
    public var angleSnap: Float = 15

    /// Set whenever the world changes and cleared on save, to drive the
    /// "unsaved changes" dot.
    public private(set) var hasUnsavedChanges = false

    /// Deltas produced since the last drain, for broadcasting to co-editors.
    private var outboundDeltas: [WorldDelta] = []

    public init(world: WorldDocument) {
        self.world = world
    }

    // MARK: Selection

    public var selectedBlocks: [BlockData] {
        // Document order, so the Inspector's multi-select header is stable.
        world.blocks.filter { selection.contains($0.id) }
    }

    public var primarySelection: BlockData? {
        selectedBlocks.first
    }

    public mutating func select(_ id: UUID?, additive: Bool = false) {
        guard let id else {
            if !additive { selection.removeAll() }
            return
        }
        if additive {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    public mutating func selectAll() {
        selection = Set(world.blocks.map(\.id))
    }

    public mutating func clearSelection() {
        selection.removeAll()
    }

    /// World-space bounds of the selection, for "frame selection".
    public var selectionBounds: BoundingBox? {
        BoundingBox.containing(selection.compactMap { world.worldBounds(of: $0) })
    }

    // MARK: Applying commands

    /// Applies a command, records it for undo, and queues its deltas.
    @discardableResult
    public mutating func perform(_ command: EditCommand) -> Bool {
        guard command.apply(to: &world) else { return false }
        history.record(command)
        outboundDeltas.append(contentsOf: command.deltas)
        hasUnsavedChanges = true
        return true
    }

    /// Applies without recording — used for edits that arrived from a peer,
    /// which must not land in the local undo stack. Undoing someone else's
    /// edit from your own history would be baffling.
    public mutating func applyRemote(_ delta: WorldDelta) {
        delta.apply(to: &world)
        pruneSelection()
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let inverse = history.popUndo() else { return false }
        inverse.apply(to: &world)
        outboundDeltas.append(contentsOf: inverse.deltas)
        pruneSelection()
        hasUnsavedChanges = true
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let command = history.popRedo() else { return false }
        command.apply(to: &world)
        outboundDeltas.append(contentsOf: command.deltas)
        pruneSelection()
        hasUnsavedChanges = true
        return true
    }

    /// Drops selected ids that no longer exist, which happens after an undo of
    /// an insert or a peer's delete.
    private mutating func pruneSelection() {
        let live = Set(world.blocks.map(\.id))
        selection.formIntersection(live)
    }

    public mutating func drainDeltas() -> [WorldDelta] {
        let deltas = outboundDeltas
        outboundDeltas.removeAll()
        return deltas
    }

    public mutating func markSaved() {
        hasUnsavedChanges = false
    }

    // MARK: Editing operations

    /// Adds a part from the palette, selects it, and returns its id.
    @discardableResult
    public mutating func addPart(_ kind: BlockData.PresetKind, at position: Vec3) -> UUID {
        var block = BlockData.preset(kind, at: position.snapped(toGridOf: gridSize))
        block.name = world.uniqueName(basedOn: block.name)
        perform(.insert(block))
        selection = [block.id]
        return block.id
    }

    public mutating func deleteSelection() {
        let blocks = selectedBlocks
        guard !blocks.isEmpty else { return }

        // Deleting a parent already removes its children, so a subtree that is
        // wholly selected must not be deleted twice — the second delete would
        // fail and, worse, the inverse would re-insert the children twice.
        var topLevel: [BlockData] = []
        let selectedIDs = Set(blocks.map(\.id))
        for block in blocks {
            let hasSelectedAncestor = world.ancestors(of: block.id).contains { selectedIDs.contains($0.id) }
            if !hasSelectedAncestor { topLevel.append(block) }
        }

        // Children are recorded too, so undo restores the whole subtree.
        let commands = topLevel.flatMap { block in
            world.subtree(of: block.id).reversed().map { EditCommand.delete($0) }
        }

        perform(.group(label: blocks.count == 1 ? "Delete \(blocks[0].name)" : "Delete \(blocks.count) parts", commands: commands))
        selection.removeAll()
    }

    public mutating func duplicateSelection() {
        let blocks = selectedBlocks
        guard !blocks.isEmpty else { return }

        var commands: [EditCommand] = []
        var newSelection: Set<UUID> = []
        // Old id → new id, so a duplicated subtree keeps its internal parent
        // links instead of re-pointing at the original.
        var idMap: [UUID: UUID] = [:]

        for block in blocks {
            for original in world.subtree(of: block.id) where idMap[original.id] == nil {
                idMap[original.id] = UUID()
            }
        }

        for block in blocks {
            for original in world.subtree(of: block.id) {
                var copy = original
                copy.id = idMap[original.id] ?? UUID()
                if let parent = original.parentID {
                    // Reparent to the duplicated parent when it is part of the
                    // copy; otherwise keep the original parent.
                    copy.parentID = idMap[parent] ?? parent
                }
                if original.id == block.id {
                    copy.name = world.uniqueName(basedOn: original.name)
                    copy.position += Vec3(gridSize > 0 ? gridSize * 2 : 1, 0, 0)
                    newSelection.insert(copy.id)
                }
                commands.append(.insert(copy))
            }
        }

        perform(.group(label: "Duplicate", commands: commands))
        selection = newSelection
    }

    /// Edits every selected block through `transform`, as one undo step.
    public mutating func mutateSelection(label: String, _ transform: (inout BlockData) -> Void) {
        let blocks = selectedBlocks
        guard !blocks.isEmpty else { return }

        var commands: [EditCommand] = []
        for block in blocks {
            var updated = block
            transform(&updated)
            guard updated != block else { continue }
            commands.append(.modify(before: block, after: updated))
        }
        guard !commands.isEmpty else { return }

        perform(commands.count == 1 ? commands[0] : .group(label: label, commands: commands))
    }

    /// Moves the selection by a world-space offset, snapping the result.
    public mutating func translateSelection(by offset: Vec3) {
        // Read the snap settings into locals first: the closure below must not
        // touch `self` while the mutating `mutateSelection` holds it.
        let grid = gridSize
        mutateSelection(label: "Move") { block in
            block.position = (block.position + offset).snapped(toGridOf: grid)
        }
    }

    public mutating func rotateSelection(byDegrees delta: Vec3) {
        let snap = angleSnap
        mutateSelection(label: "Rotate") { block in
            let current = block.rotationDegrees
            let next = Vec3(
                normalizeDegrees(current.x + delta.x),
                normalizeDegrees(current.y + delta.y),
                normalizeDegrees(current.z + delta.z)
            )
            block.rotationDegrees = snap > 0 ? next.snapped(toGridOf: snap) : next
        }
    }

    public mutating func scaleSelection(by factor: Vec3) {
        mutateSelection(label: "Scale") { block in
            // A zero or negative scale makes a block invisible and inverts its
            // normals; clamp rather than let the user create one by accident.
            block.scale = Vec3(
                Swift.max(0.05, block.scale.x * factor.x),
                Swift.max(0.05, block.scale.y * factor.y),
                Swift.max(0.05, block.scale.z * factor.z)
            )
        }
    }

    /// Reparents a block in the Explorer. Rejects moves that would create a
    /// cycle, leaving the world untouched.
    @discardableResult
    public mutating func reparent(_ id: UUID, to newParent: UUID?) -> Bool {
        guard let block = world.block(id: id) else { return false }
        guard block.parentID != newParent else { return false }
        if let newParent {
            guard world.block(id: newParent) != nil else { return false }
            guard !world.isDescendant(newParent, ofOrEqualTo: id) else { return false }
        }
        return perform(.reparent(blockID: id, from: block.parentID, to: newParent))
    }

    public mutating func setEnvironment(_ environment: EnvironmentSettings) {
        guard environment != world.environment else { return }
        perform(.setEnvironment(before: world.environment, after: environment))
    }

    public mutating func setRules(_ rules: [EventRule]) {
        guard rules != world.rules else { return }
        perform(.setRules(before: world.rules, after: rules))
    }

    public mutating func renameWorld(_ name: String) {
        world.name = name
        hasUnsavedChanges = true
    }

    // MARK: Gesture lifecycle

    /// Call when a continuous drag starts, so its per-frame edits become one
    /// undo step rather than sixty.
    public mutating func beginGesture() {
        history.beginCoalescing()
    }

    public mutating func endGesture() {
        history.endCoalescing()
    }

    // MARK: Validation

    public var issues: [WorldDocument.ValidationIssue] {
        world.validate()
    }
}
