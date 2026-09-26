import XCTest
@testable import AbloxCore

/// `WorldIndex` must give exactly what the slow, obviously-right lookups
/// give — the host and every iPad have to agree on where things are.
final class WorldIndexTests: XCTestCase {

    /// A scattered world with nesting, rotation, big plates and a few blocks
    /// that are invisible, pass-through or not colliding.
    private func randomWorld(count: Int, seed: UInt64) -> WorldDocument {
        var random = SeededRandom(seed: seed)
        var world = WorldDocument()
        world.blocks = [BlockData(name: "Ground", transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(300, 1, 300)))]
        for i in 0..<count {
            let parent = i > 10 && random.unit() < 0.3 ? world.blocks[random.integer(1, world.blocks.count - 1)].id : nil
            let rotation = random.unit() < 0.3 ? Quat.euler(degrees: Vec3(0, Float(random.integer(0, 359)), Float(random.integer(0, 30)))) : .identity
            let behaviors: [BlockBehavior] = [.none, .none, .none, .trigger, .hazard, .collectible, .bounce, .checkpoint]
            world.blocks.append(BlockData(
                name: "Part \(i)",
                shape: [.box, .sphere, .cylinder, .cone][random.integer(0, 3)],
                transform: Transform3D(
                    position: Vec3(Float(random.integer(-120, 120)), Float(random.integer(0, 20)), Float(random.integer(-120, 120))),
                    rotation: rotation,
                    scale: Vec3(Float(random.integer(1, 12)), Float(random.integer(1, 4)), Float(random.integer(1, 12)))
                ),
                hasCollision: random.unit() > 0.1,
                isVisible: random.unit() > 0.05,
                behavior: behaviors[random.integer(0, behaviors.count - 1)],
                parentID: parent
            ))
        }
        return world
    }

    func testBoundsMatchTheDocumentExactly() {
        let world = randomWorld(count: 400, seed: 7)
        let index = WorldIndex(world: world)
        for block in world.blocks {
            XCTAssertEqual(index.bounds(of: block.id), world.worldBounds(of: block.id), block.name)
            XCTAssertEqual(index.entry(for: block.id)?.position, world.worldPosition(of: block.id), block.name)
        }
    }

    func testNearbyBlocksAreTheSameAsCheckingEveryBlockInTheSameOrder() {
        let world = randomWorld(count: 600, seed: 11)
        let index = WorldIndex(world: world)
        let all = world.blocks.map { (id: $0.id, bounds: world.worldBounds(of: $0.id)!) }
        var random = SeededRandom(seed: 3)
        for _ in 0..<300 {
            let centre = Vec3(Float(random.integer(-130, 130)), Float(random.integer(-2, 22)), Float(random.integer(-130, 130)))
            let size = Vec3(Float(random.integer(1, 30)), Float(random.integer(1, 6)), Float(random.integer(1, 30)))
            let box = BoundingBox(center: centre, size: size)
            let expected = all.filter { $0.bounds.intersects(box) }.map(\.id)
            XCTAssertEqual(index.entries(near: box).map(\.id), expected)
        }
        // A query bigger than the grid falls back to a scan, same answer.
        let huge = BoundingBox(center: .zero, size: Vec3(1000, 100, 1000))
        XCTAssertEqual(index.entries(near: huge).map(\.id), all.filter { $0.bounds.intersects(huge) }.map(\.id))
    }

    func testSolidBlocksAreTheVisibleCollidingOnes() {
        let world = randomWorld(count: 200, seed: 5)
        let index = WorldIndex(world: world)
        let expected = world.blocks.filter { $0.isVisible && $0.hasCollision }.map(\.id)
        XCTAssertEqual(index.solidBlocks.map(\.id), expected)
    }

    func testTheCacheRebuildsOnlyWhenBlocksChange() {
        var world = randomWorld(count: 50, seed: 2)
        let cache = WorldIndexCache()
        let first = cache.index(for: world)
        XCTAssertEqual(cache.index(for: world).entries.count, first.entries.count)

        world.blocks[5].transform.position = Vec3(99, 0, 99)
        let moved = cache.index(for: world)
        XCTAssertEqual(moved.entry(for: world.blocks[5].id)?.position, Vec3(99, 0, 99).applyingParent(of: world, block: world.blocks[5]))
    }

    /// Kept up edit by edit — blocks added, moved, hidden, removed,
    /// re-parented — the cached index is always the one a fresh build gives.
    func testTheCacheKeptUpEditByEditMatchesAFreshIndex() {
        var world = randomWorld(count: 180, seed: 21)
        var random = SeededRandom(seed: 99)
        let cache = WorldIndexCache()
        _ = cache.index(for: world)
        for step in 0..<400 {
            let roll = random.integer(0, 9)
            let pick = random.integer(1, world.blocks.count - 1)
            switch roll {
            case 0, 1:
                // A coin dropped, sometimes hung from something.
                let parent = random.unit() < 0.3 ? world.blocks[pick].id : nil
                world.blocks.append(BlockData(name: "Drop \(step)",
                                              transform: Transform3D(position: Vec3(Float(random.integer(-100, 100)), 3, Float(random.integer(-100, 100)))),
                                              parentID: parent))
            case 2, 3, 4:
                // Moving platforms: several at once, sometimes.
                for _ in 0..<random.integer(1, 3) {
                    let k = random.integer(1, world.blocks.count - 1)
                    world.blocks[k].transform.position.x += Float(random.integer(-6, 6))
                    world.blocks[k].transform.rotation = Quat.euler(degrees: Vec3(0, Float(random.integer(0, 359)), 0))
                }
            case 5:
                world.blocks[pick].color = ColorRGBA(r: random.unit(), g: 0, b: 0, a: 1)
            case 6:
                world.blocks[pick].isVisible.toggle()
            case 7:
                world.blocks.remove(at: pick)
            case 8:
                world.blocks[pick].parentID = random.unit() < 0.5 ? nil : world.blocks[random.integer(1, world.blocks.count - 1)].id
            default:
                world.blocks[pick].transform.scale = Vec3(Float(random.integer(1, 90)), 1, Float(random.integer(1, 90)))
            }
            let kept = cache.index(for: world)
            let fresh = WorldIndex(world: world)
            XCTAssertEqual(kept.entries, fresh.entries, "step \(step)")
            XCTAssertEqual(kept.solidBlocks.map(\.id), fresh.solidBlocks.map(\.id), "step \(step)")
            XCTAssertEqual(kept.solidBlocks.map(\.bounds), fresh.solidBlocks.map(\.bounds), "step \(step)")
            if step % 10 == 0 {
                for _ in 0..<20 {
                    let box = BoundingBox(center: Vec3(Float(random.integer(-130, 130)), 5, Float(random.integer(-130, 130))),
                                          size: Vec3(Float(random.integer(1, 40)), 12, Float(random.integer(1, 40))))
                    XCTAssertEqual(kept.entries(near: box).map(\.id), fresh.entries(near: box).map(\.id), "step \(step)")
                }
            }
        }
    }

    func testTheColliderGivesTheSameAnswerThroughTheIndex() {
        // Walking and falling through a crowded world: the step against a
        // cached index must match the step that measures the world itself.
        let world = randomWorld(count: 500, seed: 13)
        let index = WorldIndex(world: world)
        var random = SeededRandom(seed: 17)
        for _ in 0..<200 {
            let position = Vec3(Float(random.integer(-100, 100)), Float(random.integer(0, 15)), Float(random.integer(-100, 100)))
            let velocity = Vec3(Float(random.integer(-8, 8)), Float(random.integer(-20, 10)), Float(random.integer(-8, 8)))
            let a = WorldCollider.resolve(position: position, velocity: velocity, world: world, deltaTime: 1.0 / 30)
            let b = WorldCollider.resolve(position: position, velocity: velocity, index: index, deltaTime: 1.0 / 30)
            XCTAssertEqual(a, b)
        }
    }

    func testDistanceToABoxIsMeasuredToItsNearestEdge() {
        let ground = BoundingBox(min: Vec3(-100, -1, -100), max: Vec3(100, 0, 100))
        XCTAssertEqual(ground.distanceSquared(to: Vec3(90, 2, 90)), 4)
        XCTAssertEqual(ground.distanceSquared(to: Vec3(0, -0.5, 0)), 0)
        let crate = BoundingBox(min: Vec3(10, 0, 0), max: Vec3(11, 1, 1))
        XCTAssertEqual(crate.distanceSquared(to: Vec3(7, 0.5, 0.5)), 9)
    }

    func testABigWorldStepsQuickly() {
        // Two thousand parts: the old per-frame cost was quadratic in this.
        let world = randomWorld(count: 2000, seed: 21)
        let cache = WorldIndexCache()
        let start = Date()
        var position = Vec3(0, 30, 0)
        var velocity = Vec3(3, 0, 2)
        for _ in 0..<120 {
            let result = WorldCollider.resolve(position: position, velocity: velocity, index: cache.index(for: world), deltaTime: 1.0 / 60)
            position = result.position
            velocity = Vec3(3, result.velocity.y - 0.3, 2)
        }
        // Two seconds of frames in well under a second, even unoptimised.
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}

private extension Vec3 {
    /// `self` as a local position of `block`, carried into world space.
    func applyingParent(of world: WorldDocument, block: BlockData) -> Vec3 {
        var moved = block
        moved.transform.position = self
        var copy = world
        if let i = copy.blocks.firstIndex(where: { $0.id == block.id }) { copy.blocks[i] = moved }
        return copy.worldPosition(of: block.id)
    }
}

/// A small deterministic generator, so a failure can be replayed.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func unit() -> Float { Float(next() % 1_000_000) / 1_000_000 }
    mutating func integer(_ low: Int, _ high: Int) -> Int { low + Int(next() % UInt64(high - low + 1)) }
}
