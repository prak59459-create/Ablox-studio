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

    public struct Entry: Sendable {
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
    public let entries: [Entry]
    /// Visible, colliding blocks — what a shot or a camera line can hit.
    public let solidBlocks: [(id: UUID, bounds: BoundingBox)]

    private let orderByID: [UUID: Int]
    private let cells: [Int64: [Int]]
    /// Blocks too big to be worth putting in every cell they cover (a
    /// ground plate, a sky dome). Checked by every query; there are few.
    private let large: [Int]

    /// Grid cells are this many metres on a side, on the ground plane.
    public static let cellSize: Float = 4
    /// A block covering more cells than this goes in `large` instead.
    static let maximumCellsPerBlock = 256

    public init(world: WorldDocument) {
        let blocks = world.blocks
        var byID: [UUID: BlockData] = [:]
        byID.reserveCapacity(blocks.count)
        var orders: [UUID: Int] = [:]
        orders.reserveCapacity(blocks.count)
        for (order, block) in blocks.enumerated() where byID[block.id] == nil {
            // First one wins, as with `WorldDocument.block(id:)`.
            byID[block.id] = block
            orders[block.id] = order
        }

        var entries: [Entry] = []
        entries.reserveCapacity(blocks.count)
        var solids: [(id: UUID, bounds: BoundingBox)] = []
        var cells: [Int64: [Int]] = [:]
        var large: [Int] = []

        for (order, block) in blocks.enumerated() {
            let transform = Self.worldTransform(of: block, lookup: byID)
            let bounds = WorldDocument.bounds(of: block, at: transform)
            let entry = Entry(id: block.id, order: order, bounds: bounds, position: transform.position,
                              isVisible: block.isVisible, hasCollision: block.hasCollision, behavior: block.behavior)
            let index = entries.count
            entries.append(entry)
            if block.isVisible, block.hasCollision { solids.append((block.id, bounds)) }

            let range = Self.cellRange(of: bounds)
            if !Self.fitsGrid(range, limit: Self.maximumCellsPerBlock) {
                large.append(index)
            } else {
                for x in range.x0...range.x1 {
                    for z in range.z0...range.z1 {
                        cells[Self.key(x, z), default: []].append(index)
                    }
                }
            }
        }

        self.entries = entries
        self.solidBlocks = solids
        self.orderByID = orders
        self.cells = cells
        self.large = large
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
        var result = block.transform
        var seen: Set<UUID> = [block.id]
        var cursor = block.parentID
        while let current = cursor, let parent = lookup[current] {
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

/// Keeps one `WorldIndex` and rebuilds it only when the blocks change.
///
/// The check is an array comparison, which is instant while the world has
/// not changed (the two arrays share storage) and a single pass when it has.
public final class WorldIndexCache: @unchecked Sendable {
    private var blocks: [BlockData]?
    private var cached: WorldIndex?
    private let lock = NSLock()

    public init() {}

    public func index(for world: WorldDocument) -> WorldIndex {
        lock.lock()
        defer { lock.unlock() }
        if let cached, let blocks, blocks == world.blocks { return cached }
        let fresh = WorldIndex(world: world)
        blocks = world.blocks
        cached = fresh
        return fresh
    }
}
