import Foundation

/// Every block's world-space bounds, worked out once, and a grid for finding
/// the ones near a place without looking at all of them.
///
/// `WorldDocument.worldBounds(of:)` is right but slow in bulk: each call
/// searches the block list for the block and again for each ancestor, so
/// asking it for every block is quadratic. The character collider, the
/// camera and the host's NPCs all did exactly that every frame, which is
/// what made worlds with a thousand parts drop well below 30 fps.
///
/// Here the list is walked once (a dictionary makes the parent lookups
/// constant time), and queries only touch the grid cells they overlap.
/// Anything returned is in document order, so code that takes "the first
/// block that …" gets the same block it did from the full list — the host
/// and every iPad still agree.
public struct WorldIndex: Sendable {

    public struct Entry: Equatable, Sendable {
        public let id: UUID
        /// Position in `WorldDocument.blocks`.
        public let order: Int
        public let bounds: BoundingBox
        public let position: Vec3
        public let isVisible: Bool
        public let hasCollision: Bool
        public let behavior: BlockBehavior
        /// Water: swum in, never stood on.
        public let isLiquid: Bool
    }

    /// Every block, in document order.
    public private(set) var entries: [Entry] = []
    /// Visible, colliding blocks — what a shot or a camera line can hit.
    public private(set) var solidBlocks: [(id: UUID, bounds: BoundingBox)] = []

    private var orderByID: [UUID: Int] = [:]
    private var cells: [Int64: [Int]] = [:]
    /// Blocks too big to be worth putting in every cell they cover (a
    /// ground plate, a sky dome). Checked by every query; there are few.
    private var large: [Int] = []
    /// Where each block is in `solidBlocks`, or -1.
    private var solidSlot: [Int] = []
    /// What hangs from each block (their positions in the list): moving a
    /// block moves those too.
    private var children: [UUID: [Int]] = [:]

    /// Grid cells are this many metres on a side, on the ground plane.
    public static let cellSize: Float = 4
    /// A block covering more cells than this goes in `large` instead.
    static let maximumCellsPerBlock = 256

    public init(world: WorldDocument) {
        append(world.blocks[...], in: world.blocks)
    }

    // MARK: Keeping up

    // A round changes the world all the time — a coin appears, a platform
    // slides — and starting again from nothing each time costs a pass over
    // every block. These two cover what almost every change is, and give up
    // (so the caller starts again) on anything else.

    /// Adds blocks that were put on the end of the world. Both paths go
    /// through here, so a grown index is exactly the one a fresh build
    /// would make.
    mutating func append(_ added: ArraySlice<BlockData>, in blocks: [BlockData]) {
        // Room for everything at once on a fresh build; a block or two added
        // later just grows the lists (reserving the exact size each time
        // would copy them every time).
        if entries.isEmpty {
            entries.reserveCapacity(blocks.count)
            solidSlot.reserveCapacity(blocks.count)
        }
        // Every new block is findable first: one may hang from another
        // added in the same batch.
        for order in added.indices where orderByID[blocks[order].id] == nil {
            // First one wins, as with `WorldDocument.block(id:)`.
            orderByID[blocks[order].id] = order
        }
        for order in added.indices {
            let block = blocks[order]
            if let parent = block.parentID { children[parent, default: []].append(order) }
            let entry = makeEntry(block, order: order, in: blocks)
            entries.append(entry)
            if block.isSolidForPlayers {
                solidSlot.append(solidBlocks.count)
                solidBlocks.append((block.id, entry.bounds))
            } else {
                solidSlot.append(-1)
            }
            place(order, bounds: entry.bounds)
        }
    }

    /// Re-reads blocks changed where they stand: moved, turned, resized,
    /// recoloured — and everything hanging from them, which moved too.
    /// `blocks` may be longer than the index (blocks added on the end are
    /// for `append` next); only the ones the index has are read. The caller
    /// has checked that none was replaced or given a different parent.
    /// False, with nothing changed, when a block started or stopped being
    /// solid.
    mutating func update(orders changed: [Int], in blocks: [BlockData]) -> Bool {
        guard blocks.count >= entries.count else { return false }
        for order in changed {
            let block = blocks[order]
            guard order < entries.count, block.id == entries[order].id, block.isSolidForPlayers == (solidSlot[order] >= 0) else { return false }
        }
        // A model hung from one block moves with it: its parts are read again too.
        var seen = Set(changed)
        var all = changed
        var cursor = 0
        while cursor < all.count {
            let id = blocks[all[cursor]].id
            cursor += 1
            for child in children[id] ?? [] where child < entries.count && seen.insert(child).inserted {
                guard blocks[child].isSolidForPlayers == (solidSlot[child] >= 0) else { return false }
                all.append(child)
            }
        }
        for order in all {
            let block = blocks[order], old = entries[order]
            let entry = makeEntry(block, order: order, in: blocks)
            entries[order] = entry
            if solidSlot[order] >= 0 { solidBlocks[solidSlot[order]].bounds = entry.bounds }
            if Self.cellRange(of: entry.bounds) != Self.cellRange(of: old.bounds) {
                unplace(order, bounds: old.bounds)
                place(order, bounds: entry.bounds)
            }
        }
        return true
    }

    private func makeEntry(_ block: BlockData, order: Int, in blocks: [BlockData]) -> Entry {
        let transform = Self.worldTransform(of: block) { id in orderByID[id].map { blocks[$0] } }
        let bounds = WorldDocument.bounds(of: block, at: transform)
        // Water is never solid, whatever its collision says.
        return Entry(id: block.id, order: order, bounds: bounds, position: transform.position,
                     isVisible: block.isVisible, hasCollision: block.hasCollision && !block.material.isLiquid,
                     behavior: block.behavior, isLiquid: block.material.isLiquid)
    }

    private mutating func place(_ order: Int, bounds: BoundingBox) {
        let range = Self.cellRange(of: bounds)
        guard Self.fitsGrid(range, limit: Self.maximumCellsPerBlock) else {
            large.append(order)
            return
        }
        for x in range.x0...range.x1 {
            for z in range.z0...range.z1 {
                cells[Self.key(x, z), default: []].append(order)
            }
        }
    }

    private mutating func unplace(_ order: Int, bounds: BoundingBox) {
        let range = Self.cellRange(of: bounds)
        guard Self.fitsGrid(range, limit: Self.maximumCellsPerBlock) else {
            large.removeAll { $0 == order }
            return
        }
        for x in range.x0...range.x1 {
            for z in range.z0...range.z1 {
                let key = Self.key(x, z)
                cells[key]?.removeAll { $0 == order }
                if cells[key]?.isEmpty == true { cells[key] = nil }
            }
        }
    }

    // MARK: Lookup

    public func entry(for id: UUID) -> Entry? {
        guard let order = orderByID[id] else { return nil }
        return entries[order]
    }

    public func bounds(of id: UUID) -> BoundingBox? {
        entry(for: id)?.bounds
    }

    /// Every block whose bounds touch `box` (inclusively), in document order.
    public func entries(near box: BoundingBox) -> [Entry] {
        let range = Self.cellRange(of: box)
        // A query bigger than the grid is worth is just a scan.
        guard Self.fitsGrid(range, limit: 4 * Self.maximumCellsPerBlock) else {
            return entries.filter { $0.bounds.intersects(box) }
        }

        var found = Set<Int>()
        for x in range.x0...range.x1 {
            for z in range.z0...range.z1 {
                guard let list = cells[Self.key(x, z)] else { continue }
                for index in list where entries[index].bounds.intersects(box) {
                    found.insert(index)
                }
            }
        }
        for index in large where entries[index].bounds.intersects(box) {
            found.insert(index)
        }
        return found.sorted().map { entries[$0] }
    }

    // MARK: Building

    /// The same composition, in the same order, as
    /// `WorldDocument.worldTransform(of:)` — so the numbers match exactly —
    /// but with each parent found in a dictionary instead of a search.
    static func worldTransform(of block: BlockData, lookup: [UUID: BlockData]) -> Transform3D {
        worldTransform(of: block) { lookup[$0] }
    }

    static func worldTransform(of block: BlockData, parent find: (UUID) -> BlockData?) -> Transform3D {
        var result = block.transform
        guard block.parentID != nil else { return result }
        var seen: Set<UUID> = [block.id]
        var cursor = block.parentID
        while let current = cursor, let parent = find(current) {
            guard seen.insert(current).inserted else { break }
            result = result.concatenating(parent: parent.transform)
            cursor = parent.parentID
        }
        return result
    }

    private static func cell(_ value: Float) -> Int {
        guard value.isFinite else { return value > 0 ? Int(Int32.max) : Int(Int32.min) }
        let scaled = (value / cellSize).rounded(.down)
        return Int(Swift.max(Float(Int32.min), Swift.min(Float(Int32.max), scaled)))
    }

    private static func cellRange(of box: BoundingBox) -> (x0: Int, x1: Int, z0: Int, z1: Int) {
        (cell(box.min.x), cell(box.max.x), cell(box.min.z), cell(box.max.z))
    }

    /// True when the range covers at least one and at most `limit` cells.
    /// Width and depth are checked first so a huge box cannot overflow.
    private static func fitsGrid(_ range: (x0: Int, x1: Int, z0: Int, z1: Int), limit: Int) -> Bool {
        let width = range.x1 - range.x0 + 1
        let depth = range.z1 - range.z0 + 1
        guard width > 0, depth > 0, width <= limit, depth <= limit else { return false }
        return width * depth <= limit
    }

    private static func key(_ x: Int, _ z: Int) -> Int64 {
        (Int64(x) << 32) | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: z)))
    }
}

/// Keeps one `WorldIndex` up to date with the blocks.
///
/// While the world has not changed (its `blockRevision` is the one the index
/// was made at) the check is instant. When it has, each block is compared
/// with the few fields its entry was made from: blocks added on the end and
/// blocks changed where they stand — a coin dropped, a platform sliding, a
/// character's root moved with its parts, which is nearly every change in a
/// round — are folded into the index; anything else builds it again.
///
/// The cache keeps only those fields, never the block list itself: holding
/// on to the list made every change to the world copy all of it.
public final class WorldIndexCache: @unchecked Sendable {
    /// What a block's entry is made from.
    private struct Key {
        let id: UUID
        let transform: Transform3D
        let parentID: UUID?
        let shape: BlockShape
        let isVisible: Bool
        let hasCollision: Bool
        let behavior: BlockBehavior
        let material: MaterialKind

        init(_ block: BlockData) {
            id = block.id
            transform = block.transform
            parentID = block.parentID
            shape = block.shape
            isVisible = block.isVisible
            hasCollision = block.hasCollision
            behavior = block.behavior
            material = block.material
        }

        func matches(_ block: BlockData) -> Bool {
            id == block.id && transform == block.transform && parentID == block.parentID && isVisible == block.isVisible
                && hasCollision == block.hasCollision && Self.sameCase(shape, block.shape) && Self.sameCase(behavior, block.behavior)
                && Self.sameCase(material, block.material)
        }

        /// The same case of an enum with no payload. `==` on these goes
        /// through their text raw values, which was most of the comparison.
        private static func sameCase<T>(_ a: T, _ b: T) -> Bool {
            withUnsafeBytes(of: a) { x in withUnsafeBytes(of: b) { y in x.elementsEqual(y) } }
        }
    }

    private var keys: [Key] = []
    private var revision: UInt64?
    private var cached: WorldIndex?
    private let lock = NSLock()

    public init() {}

    public func index(for world: WorldDocument) -> WorldIndex {
        lock.lock()
        defer { lock.unlock() }
        if let index = cached, revision == world.blockRevision.value { return index }
        let now = world.blocks
        if var index = cached, now.count >= keys.count {
            // Let go of the cached copy, so the one being brought up to date
            // is the only one and grows in place instead of being copied.
            cached = nil
            var changed: [Int] = []
            var tidy = true
            let limit = Swift.max(8, keys.count / 8)
            // Only the blocks the world's journal says were changed, when it
            // goes back far enough: a script moving one block used to make
            // the next look at the index check every block in the world.
            let suspects: [Int]
            if let revision, let journal = world.blockJournal.orders(since: revision) {
                suspects = Set(journal).filter { $0 < keys.count }.sorted()
            } else {
                suspects = Array(keys.indices)
            }
            for order in suspects where !keys[order].matches(now[order]) {
                // A block replaced or hung from something else: start again.
                guard keys[order].id == now[order].id, keys[order].parentID == now[order].parentID else {
                    tidy = false
                    break
                }
                changed.append(order)
                if changed.count > limit {
                    tidy = false
                    break
                }
            }
            if tidy, changed.isEmpty || index.update(orders: changed, in: now) {
                for order in changed { keys[order] = Key(now[order]) }
                if now.count > keys.count {
                    let added = now[keys.count...]
                    index.append(added, in: now)
                    keys.append(contentsOf: added.map(Key.init))
                }
                return keep(index, world)
            }
        }
        keys = now.map(Key.init)
        return keep(WorldIndex(world: world), world)
    }

    private func keep(_ index: WorldIndex, _ world: WorldDocument) -> WorldIndex {
        cached = index
        revision = world.blockRevision.value
        return index
    }
}

/// Where each block is in a world's list, by id. A script moving sixty
/// characters a tick looked each one up by reading through every block, and
/// that was most of the host's time in a big world.
///
/// Copies of a world share one, and every answer is checked against the
/// list it is asked about, so it is never wrong: at worst it is built again.
/// Two worlds are equal or not whatever theirs hold.
struct BlockOrders: Hashable, Sendable {
    private let storage = Storage()

    static func == (lhs: BlockOrders, rhs: BlockOrders) -> Bool { true }
    func hash(into hasher: inout Hasher) {}

    func order(of id: UUID, in blocks: [BlockData], revision: UInt64, journal: BlockJournal) -> Int? {
        storage.order(of: id, in: blocks, revision: revision, journal: journal)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var orders: [UUID: Int] = [:]
        /// The blocks it was last built from, so a block that is not there
        /// does not build it again until something changes.
        private var builtFor: UInt64?

        func order(of id: UUID, in blocks: [BlockData], revision: UInt64, journal: BlockJournal) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            if let order = orders[id], order < blocks.count, blocks[order].id == id { return order }
            // Small worlds are quicker to read through than to map.
            guard blocks.count > 32 else { return blocks.firstIndex { $0.id == id } }
            if builtFor == revision { return nil }
            if let builtFor, let changed = journal.orders(since: builtFor) {
                // Only blocks added or changed one at a time since: a script
                // making a hundred blocks does not map the world a hundred times.
                for order in changed where order < blocks.count {
                    orders[blocks[order].id] = order
                }
            } else {
                orders.removeAll(keepingCapacity: true)
                orders.reserveCapacity(blocks.count)
                for (order, block) in blocks.enumerated() where orders[block.id] == nil {
                    orders[block.id] = order
                }
            }
            builtFor = revision
            guard let order = orders[id], order < blocks.count, blocks[order].id == id else { return nil }
            return order
        }
    }
}

/// The blocks changed one at a time since some revision, in order: what a
/// cache built at that revision has to look at again, instead of every
/// block. Anything else done to the blocks (a removal, a whole new list)
/// clears it, and then a cache looks at everything as before.
///
/// Revisions are never reused, even between copies of a world, so a cache
/// built from one copy never mistakes another copy's journal for its own.
struct BlockJournal: Hashable, Sendable {
    /// The revision before the first change written down.
    private var base: UInt64?
    private var revisions: [UInt64] = []
    private var orders: [Int] = []

    static let capacity = 256

    static func == (lhs: BlockJournal, rhs: BlockJournal) -> Bool { true }
    func hash(into hasher: inout Hasher) {}

    mutating func note(order: Int, from before: UInt64, to after: UInt64) {
        if base == nil || (revisions.last ?? base) != before {
            base = before
            revisions.removeAll(keepingCapacity: true)
            orders.removeAll(keepingCapacity: true)
        } else if revisions.count >= Self.capacity {
            let dropped = Self.capacity / 2
            base = revisions[dropped - 1]
            revisions.removeFirst(dropped)
            orders.removeFirst(dropped)
        }
        revisions.append(after)
        orders.append(order)
    }

    /// The blocks changed since `revision`, or nil when the journal does not
    /// go back that far (or is another world's).
    func orders(since revision: UInt64) -> ArraySlice<Int>? {
        if revision == base { return orders[...] }
        guard let at = revisions.lastIndex(of: revision) else { return nil }
        return orders[(at + 1)...]
    }
}

/// A number that is different every time a world's blocks change. Copies of
/// a world share it until one of them changes, so two worlds with the same
/// number have the same blocks. Never saved, and two worlds are equal or not
/// whatever theirs are.
public struct BlockRevision: Hashable, Sendable {
    public let value: UInt64

    public static func == (lhs: BlockRevision, rhs: BlockRevision) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}

    static func next() -> BlockRevision {
        BlockRevision(value: counter.next())
    }

    private static let counter = RevisionCounter()
}

private final class RevisionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        last &+= 1
        return last
    }
}
