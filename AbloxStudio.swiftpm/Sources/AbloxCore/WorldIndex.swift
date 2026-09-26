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
    /// Blocks something else hangs from: moving one moves those too.
    private var parents: Set<UUID> = []

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
        entries.reserveCapacity(blocks.count)
        solidSlot.reserveCapacity(blocks.count)
        // Every new block is findable first: one may hang from another
        // added in the same batch.
        for order in added.indices where orderByID[blocks[order].id] == nil {
            // First one wins, as with `WorldDocument.block(id:)`.
            orderByID[blocks[order].id] = order
        }
        for order in added.indices {
            let block = blocks[order]
            if let parent = block.parentID { parents.insert(parent) }
            let entry = makeEntry(block, order: order, in: blocks)
            entries.append(entry)
            if block.isVisible, block.hasCollision {
                solidSlot.append(solidBlocks.count)
                solidBlocks.append((block.id, entry.bounds))
            } else {
                solidSlot.append(-1)
            }
            place(order, bounds: entry.bounds)
        }
    }

    /// Re-reads blocks changed where they stand: moved, turned, resized,
    /// recoloured. False, with nothing changed, when that could leave the
    /// index wrong — a block that others hang from (they moved too), one
    /// given a different parent or identity, or one that started or
    /// stopped being solid.
    mutating func update(orders changed: [Int], in blocks: [BlockData], was before: [BlockData]) -> Bool {
        guard blocks.count == entries.count, before.count == entries.count else { return false }
        for order in changed {
            let block = blocks[order]
            guard block.id == before[order].id, block.parentID == before[order].parentID, !parents.contains(block.id),
                  (block.isVisible && block.hasCollision) == (solidSlot[order] >= 0) else { return false }
        }
        for order in changed {
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
        return Entry(id: block.id, order: order, bounds: bounds, position: transform.position,
                     isVisible: block.isVisible, hasCollision: block.hasCollision, behavior: block.behavior)
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
/// The check is an array comparison, which is instant while the world has
/// not changed (the two arrays share storage) and a single pass when it has.
/// Blocks added on the end, and a few blocks moved where they stand — a
/// coin dropped, a platform sliding, which is nearly every change in a round
/// — are folded into the index; anything else builds it again.
public final class WorldIndexCache: @unchecked Sendable {
    private var blocks: [BlockData]?
    private var cached: WorldIndex?
    private let lock = NSLock()

    public init() {}

    public func index(for world: WorldDocument) -> WorldIndex {
        lock.lock()
        defer { lock.unlock() }
        let now = world.blocks
        if var index = cached, let old = blocks {
            if old == now { return index }
            if now.count > old.count, now[..<old.count].elementsEqual(old) {
                index.append(now[old.count...], in: now)
                return keep(index, now)
            }
            if now.count == old.count {
                var changed: [Int] = []
                let limit = Swift.max(8, now.count / 8)
                for order in now.indices where now[order] != old[order] {
                    changed.append(order)
                    if changed.count > limit { break }
                }
                if changed.count <= limit, index.update(orders: changed, in: now, was: old) {
                    return keep(index, now)
                }
            }
        }
        return keep(WorldIndex(world: world), now)
    }

    private func keep(_ index: WorldIndex, _ now: [BlockData]) -> WorldIndex {
        blocks = now
        cached = index
        return index
    }
}
