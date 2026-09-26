import Foundation

/// `block("Door")` and `blocks("coin")` without searching every block.
///
/// Scripts ask for blocks by name and tag constantly — every tick, every
/// touch — and each call used to walk the whole world (twice for a name that
/// was not there). The answers only change when a block is added, removed,
/// renamed or retagged, so they are worked out once and kept until then.
/// Blocks moving, recolouring or hiding, which is most of what happens in a
/// round, leave them alone.
struct BlockLookup {
    /// The first block with each exact name, in document order.
    private(set) var firstByName: [String: UUID] = [:]
    /// The same with case ignored, for `block("door")`.
    private(set) var firstByFoldedName: [String: UUID] = [:]
    /// Every block with a tag (case ignored), in document order.
    private(set) var byTag: [String: [UUID]] = [:]
    /// What each block was called and tagged when this was built, so an
    /// update can tell whether it changed either.
    private var labels: [UUID: (name: String, tags: [String])] = [:]

    init(blocks: [BlockData]) {
        for block in blocks { record(block) }
    }

    /// A block a script just made, which goes on the end of the world: it
    /// is added here rather than everything being worked out again, so a
    /// game dropping twenty coins at once does not pay for it twenty times.
    /// False for a block already known (the insert is really an update).
    mutating func add(_ block: BlockData) -> Bool {
        guard labels[block.id] == nil else { return false }
        record(block)
        return true
    }

    private mutating func record(_ block: BlockData) {
        if firstByName[block.name] == nil { firstByName[block.name] = block.id }
        let folded = block.name.lowercased()
        if firstByFoldedName[folded] == nil { firstByFoldedName[folded] = block.id }
        for tag in Set(block.tags.map { $0.lowercased() }) {
            byTag[tag, default: []].append(block.id)
        }
        if labels[block.id] == nil { labels[block.id] = (block.name, block.tags) }
    }

    func firstBlock(named name: String) -> UUID? {
        firstByName[name] ?? firstByFoldedName[name.lowercased()]
    }

    func blocks(taggedWith tag: String) -> [UUID] {
        byTag[tag.lowercased()] ?? []
    }

    /// Whether this edit could change an answer.
    func isAffected(by delta: WorldDelta) -> Bool {
        switch delta {
        case .insert, .remove, .reparent:
            return true
        case let .update(block):
            guard let label = labels[block.id] else { return true }
            return label.name != block.name || label.tags != block.tags
        case .environment, .rulesReplaced, .scriptsReplaced, .scriptSourceChanged:
            return false
        }
    }
}

extension GameRuntime {
    var blockLookup: BlockLookup {
        if let cached = lookupCache { return cached }
        let fresh = BlockLookup(blocks: world.blocks)
        lookupCache = fresh
        return fresh
    }

    /// Called just before `delta` reaches the world.
    func forgetLookup(ifAffectedBy delta: WorldDelta) {
        guard var cached = lookupCache else { return }
        if case let .insert(block) = delta, cached.add(block) {
            lookupCache = cached
        } else if cached.isAffected(by: delta) {
            lookupCache = nil
        }
    }
}
