import Foundation

/// A reversible edit.
///
/// Undo is implemented as **explicit inverse commands** rather than by
/// snapshotting the whole world before every change. A world with a few
/// hundred blocks is a sizeable JSON document; keeping fifty snapshots of it
/// on an iPad would be megabytes of memory to support a Ctrl-Z. An inverse
/// command is a handful of bytes.
///
/// It also gives the network layer exactly what it needs for free: every
/// command already knows how to express itself as a `WorldDelta`, which is
/// what gets broadcast to co-editing peers.
public enum EditCommand: Hashable, Sendable {
    case insert(BlockData)
    case delete(BlockData)
    /// `before` is kept so the inverse is exact rather than reconstructed.
    case modify(before: BlockData, after: BlockData)
    case reparent(blockID: UUID, from: UUID?, to: UUID?)
    case setEnvironment(before: EnvironmentSettings, after: EnvironmentSettings)
    case setRules(before: [EventRule], after: [EventRule])
    /// The world's `.absc` files, all at once: adding, renaming, deleting
    /// and editing a file are each one of these.
    case setScripts(before: [ScriptFile], after: [ScriptFile])
    /// Several edits that undo as one — a multi-selection drag, say.
    indirect case group(label: String, commands: [EditCommand])

    /// Applies this command to a world. Returns false when it could not be
    /// applied, which happens when a command races a delete from a peer.
    @discardableResult
    public func apply(to world: inout WorldDocument) -> Bool {
        switch self {
        case let .insert(block):
            if world.index(of: block.id) != nil { return world.update(block) }
            world.insert(block)
            return true

        case let .delete(block):
            return !world.remove(id: block.id).isEmpty

        case let .modify(_, after):
            return world.update(after)

        case let .reparent(blockID, _, to):
            return world.setParent(of: blockID, to: to)

        case let .setEnvironment(_, after):
            world.environment = after
            world.modifiedAt = Date()
            return true

        case let .setRules(_, after):
            world.rules = after
            world.modifiedAt = Date()
            return true

        case let .setScripts(_, after):
            world.scripts = after
            world.modifiedAt = Date()
            return true

        case let .group(_, commands):
            var anyApplied = false
            for command in commands where command.apply(to: &world) {
                anyApplied = true
            }
            return anyApplied
        }
    }

    /// The command that undoes this one.
    public var inverse: EditCommand {
        switch self {
        case let .insert(block):
            return .delete(block)
        case let .delete(block):
            return .insert(block)
        case let .modify(before, after):
            return .modify(before: after, after: before)
        case let .reparent(blockID, from, to):
            return .reparent(blockID: blockID, from: to, to: from)
        case let .setEnvironment(before, after):
            return .setEnvironment(before: after, after: before)
        case let .setRules(before, after):
            return .setRules(before: after, after: before)
        case let .setScripts(before, after):
            return .setScripts(before: after, after: before)
        case let .group(label, commands):
            // Reversed: undoing a group must unwind it in the opposite order,
            // or a delete-then-insert pair would resurrect in the wrong place.
            return .group(label: label, commands: commands.reversed().map(\.inverse))
        }
    }

    /// How the command is described in the undo button's tooltip.
    public var label: String {
        switch self {
        case let .insert(block): return "Add \(block.name)"
        case let .delete(block): return "Delete \(block.name)"
        case let .modify(_, after): return "Edit \(after.name)"
        case .reparent: return "Move in tree"
        case .setEnvironment: return "Change environment"
        case .setRules: return "Edit rules"
        case .setScripts: return "Edit scripts"
        case let .group(label, _): return label
        }
    }

    /// The deltas a co-editing peer needs to see. One command can be several
    /// deltas (a group), and `.delete` is deliberately a single delta because
    /// `WorldDocument.remove` already takes the subtree with it.
    public var deltas: [WorldDelta] {
        switch self {
        case let .insert(block): return [.insert(block)]
        case let .delete(block): return [.remove(blockID: block.id)]
        case let .modify(_, after): return [.update(after)]
        case let .reparent(blockID, _, to): return [.reparent(blockID: blockID, newParent: to)]
        case let .setEnvironment(_, after): return [.environment(after)]
        case let .setRules(_, after): return [.rulesReplaced(after)]
        case let .setScripts(_, after): return [.scriptsReplaced(after)]
        case let .group(_, commands): return commands.flatMap(\.deltas)
        }
    }

    /// Whether two consecutive commands should be merged into one undo step.
    ///
    /// Dragging a block emits a `modify` every frame. Without coalescing,
    /// undo would step back through sixty intermediate positions instead of
    /// returning the block to where it started.
    public func canCoalesce(with next: EditCommand) -> Bool {
        switch (self, next) {
        case let (.modify(_, after), .modify(nextBefore, _)):
            return after.id == nextBefore.id
        case (.setScripts, .setScripts):
            // A burst of typing is one undo step, like a drag.
            return true
        default:
            return false
        }
    }

    /// Merges a coalescable pair, keeping this command's original `before`.
    public func coalesced(with next: EditCommand) -> EditCommand {
        guard canCoalesce(with: next) else { return next }
        switch (self, next) {
        case let (.modify(before, _), .modify(_, after)):
            return .modify(before: before, after: after)
        case let (.setScripts(before, _), .setScripts(_, after)):
            return .setScripts(before: before, after: after)
        default:
            return next
        }
    }
}

// MARK: - Undo stack

/// Bounded undo/redo history.
public struct EditHistory: Sendable {
    /// Fifty steps is plenty for hand-editing and bounds worst-case memory.
    public static let defaultLimit = 50

    private var undoStack: [EditCommand] = []
    private var redoStack: [EditCommand] = []
    private let limit: Int

    /// Set while a continuous gesture is in progress, so its per-frame
    /// commands coalesce into one entry instead of fifty.
    private var isCoalescing = false
    /// How deep the stack was when the gesture began. Only a command recorded
    /// during the gesture may be merged into: otherwise opening the script
    /// editor straight after creating a file would fold the typing into the
    /// creation, and one undo would delete the file.
    private var gestureBase = 0

    public init(limit: Int = EditHistory.defaultLimit) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }
    public var depth: Int { undoStack.count }

    /// Records a command that has already been applied.
    public mutating func record(_ command: EditCommand) {
        // Any new edit invalidates the redo branch — the usual linear-history
        // model, which is what people expect from Cmd-Z.
        redoStack.removeAll()

        if isCoalescing, undoStack.count > gestureBase, let last = undoStack.last, last.canCoalesce(with: command) {
            undoStack[undoStack.count - 1] = last.coalesced(with: command)
            return
        }

        undoStack.append(command)
        if undoStack.count > limit {
            let dropped = undoStack.count - limit
            undoStack.removeFirst(dropped)
            gestureBase = max(0, gestureBase - dropped)
        }
    }

    /// Called when a continuous gesture starts. Commands recorded until
    /// `endCoalescing()` merge into a single undo step.
    public mutating func beginCoalescing() {
        isCoalescing = true
        gestureBase = undoStack.count
    }

    public mutating func endCoalescing() {
        isCoalescing = false
    }

    /// Pops the next undo command. The caller applies it.
    public mutating func popUndo() -> EditCommand? {
        guard let command = undoStack.popLast() else { return nil }
        redoStack.append(command)
        return command.inverse
    }

    public mutating func popRedo() -> EditCommand? {
        guard let command = redoStack.popLast() else { return nil }
        undoStack.append(command)
        return command
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        isCoalescing = false
    }
}
