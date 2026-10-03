import XCTest
@testable import AbloxCore

/// The pieces that keep big games smooth: blocks compared quickly, many
/// blocks baked into one mesh, world changes gathered up, SwiftUI told less
/// often, and the governor trading a few pixels for a steady frame rate.
final class RenderSpeedTests: XCTestCase {

    // MARK: Comparing blocks

    func testBlockEnumsCompareAndHashByCase() {
        for a in BlockShape.allCases {
            for b in BlockShape.allCases {
                XCTAssertEqual(a == b, a.rawValue == b.rawValue)
            }
            XCTAssertEqual(Set([a, a]).count, 1)
        }
        for a in MaterialKind.allCases {
            for b in MaterialKind.allCases { XCTAssertEqual(a == b, a.rawValue == b.rawValue) }
        }
        for a in BlockBehavior.allCases {
            for b in BlockBehavior.allCases { XCTAssertEqual(a == b, a.rawValue == b.rawValue) }
        }
        for a in ParticleKind.allCases {
            for b in ParticleKind.allCases { XCTAssertEqual(a == b, a.rawValue == b.rawValue) }
        }
        XCTAssertEqual(Set(MaterialKind.allCases).count, MaterialKind.allCases.count)
        XCTAssertEqual(Set(BlockBehavior.allCases).count, BlockBehavior.allCases.count)
        // A decoded value is the same case as a made one.
        let decoded = try? JSONDecoder().decode(BlockShape.self, from: Data("\"cone\"".utf8))
        XCTAssertEqual(decoded, .cone)
        XCTAssertEqual(Set([BlockShape.cone, decoded!]).count, 1)
    }

    func testBlocksStillCompareByEveryField() {
        var a = BlockData(name: "A")
        let b = a
        XCTAssertEqual(a, b)
        a.material = .neon
        XCTAssertNotEqual(a, b)
        a = b
        a.shape = .sphere
        XCTAssertNotEqual(a, b)
        a = b
        a.behavior = .hazard
        XCTAssertNotEqual(a, b)
    }

    // MARK: Merged meshes

    func testTheBoxAndPlaneAreWellFormedAndFaceOutward() {
        let box = MeshGeometry.box()
        XCTAssertTrue(box.isWellFormed)
        XCTAssertEqual(box.vertexCount, 24)
        XCTAssertEqual(box.triangleCount, 12)
        XCTAssertEqual(box.bounds, BoundingBox(min: Vec3(-0.5, -0.5, -0.5), max: Vec3(0.5, 0.5, 0.5)))
        for triangle in 0..<box.triangleCount {
            let face = box.faceNormal(ofTriangle: triangle)
            let normal = box.normals[Int(box.indices[triangle * 3])]
            XCTAssertGreaterThan(face.dot(normal), 0, "triangle \(triangle) faces in")
        }
        let plane = MeshGeometry.plane()
        XCTAssertTrue(plane.isWellFormed)
        for triangle in 0..<plane.triangleCount {
            XCTAssertGreaterThan(plane.faceNormal(ofTriangle: triangle).y, 0)
        }
    }

    func testMergingPlacesEachPieceWhereItsBlockIs() {
        let wall = Transform3D(position: Vec3(10, 2, -4), rotation: Quat.yaw(degrees: 90), scale: Vec3(8, 4, 1))
        let post = Transform3D(position: Vec3(-3, 1, 0), scale: Vec3(1, 2, 1))
        let merged = MeshGeometry.merged([
            .init(geometry: .box(), transform: wall, textureRepeats: 4),
            .init(geometry: .cylinder(height: 1, radius: 0.5, segments: 8), transform: post)
        ])
        XCTAssertTrue(merged.isWellFormed)
        XCTAssertEqual(merged.vertexCount, 24 + MeshGeometry.cylinder(height: 1, radius: 0.5, segments: 8).vertexCount)

        // The wall's corners are where the world index says its bounds are.
        let wallPart = MeshGeometry(positions: Array(merged.positions[0..<24]), normals: Array(merged.normals[0..<24]),
                                    textureCoordinates: Array(merged.textureCoordinates[0..<24]), indices: Array(MeshGeometry.box().indices))
        var block = BlockData(name: "Wall")
        block.transform = wall
        let expected = WorldDocument.bounds(of: block, at: wall)
        XCTAssertEqual(wallPart.bounds.min.x, expected.min.x, accuracy: 0.001)
        XCTAssertEqual(wallPart.bounds.max.z, expected.max.z, accuracy: 0.001)
        XCTAssertEqual(wallPart.bounds.max.y, 4, accuracy: 0.001)
        // Turned a quarter: the long side now runs along z.
        XCTAssertEqual(wallPart.bounds.max.z - wallPart.bounds.min.z, 8, accuracy: 0.001)
        // Normals stay unit length and square to the surface.
        for n in merged.normals { XCTAssertEqual(n.length, 1, accuracy: 0.001) }
        // The pattern repeats four times across the wall, once on the post.
        XCTAssertEqual(merged.textureCoordinates[0..<24].map(\.u).max() ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(merged.textureCoordinates[24...].map(\.u).max() ?? 0, 1, accuracy: 0.001)
        // The post's indices point at the post's vertices.
        let firstPostIndex = merged.indices[36]
        XCTAssertGreaterThanOrEqual(firstPostIndex, 24)
    }

    func testAMirroredBlockStillFacesOutward() {
        let flipped = Transform3D(position: .zero, scale: Vec3(-1, 1, 1))
        let merged = MeshGeometry.merged([.init(geometry: .box(), transform: flipped)])
        for triangle in 0..<merged.triangleCount {
            let face = merged.faceNormal(ofTriangle: triangle)
            let normal = merged.normals[Int(merged.indices[triangle * 3])]
            XCTAssertGreaterThan(face.dot(normal), 0)
        }
    }

    func testOnlyPlainStillBlocksAreMerged() {
        var plain = BlockData(name: "Floor")
        XCTAssertTrue(RenderMerging.canMerge(plain, hasChildren: false))
        XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: true))
        plain.isVisible = false
        XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: false))
        plain.isVisible = true
        plain.color.a = 0.5
        XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: false))
        plain.color.a = 1
        plain.material = .glass
        XCTAssertEqual(RenderMerging.canMerge(plain, hasChildren: false), MaterialKind.glass.alphaScale >= 0.999)
        plain.material = .plastic
        for moving in [BlockBehavior.elevator, .door, .vehicle, .pushable, .collectible, .disappear] {
            plain.behavior = moving
            XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: false), "\(moving)")
        }
        plain.behavior = .hazard
        XCTAssertTrue(RenderMerging.canMerge(plain, hasChildren: false))
        plain.behavior = .none
        plain.animation = BlockAnimation(kind: .spin)
        XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: false))
        plain.animation = nil
        plain.label = BlockLabel(lines: [BlockLabel.Line(text: "Shop")])
        XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: false))
        plain.label = nil
        plain.isAnchored = false
        XCTAssertFalse(RenderMerging.canMerge(plain, hasChildren: false))
    }

    func testOnlyChangesThatShowTakeABlockOutOfItsMesh() {
        let block = BlockData(name: "Crate")
        var renamed = block
        renamed.name = "Box"
        renamed.tags = ["loot"]
        renamed.scoreValue = 5
        renamed.hasCollision = false
        XCTAssertTrue(RenderMerging.looksTheSame(block, renamed))
        var moved = block
        moved.position.x += 1
        XCTAssertFalse(RenderMerging.looksTheSame(block, moved))
        var painted = block
        painted.color.r = 0.1
        XCTAssertFalse(RenderMerging.looksTheSame(block, painted))
        var labelled = block
        labelled.label = BlockLabel(text: "Hi")
        XCTAssertFalse(RenderMerging.looksTheSame(block, labelled))
        var freed = block
        freed.isAnchored = false
        XCTAssertFalse(RenderMerging.looksTheSame(block, freed))
    }

    func testASeeThroughRootDrawsNothing() {
        var root = BlockData(name: "Meme")
        root.color.a = 0
        XCTAssertTrue(RenderMerging.drawsNothing(root))
        root.color.a = 1
        XCTAssertFalse(RenderMerging.drawsNothing(root))
    }

    func testPatchesSplitTheMapIntoSquares() {
        XCTAssertEqual(RenderMerging.patch(containing: Vec3(1, 0, 1)), RenderMerging.patch(containing: Vec3(47, 9, 47)))
        XCTAssertNotEqual(RenderMerging.patch(containing: Vec3(1, 0, 1)), RenderMerging.patch(containing: Vec3(49, 0, 1)))
        XCTAssertEqual(RenderMerging.patch(containing: Vec3(-1, 0, -1)), RenderMerging.Patch(x: -1, z: -1))
        XCTAssertEqual(RenderMerging.patch(containing: Vec3(.nan, 0, .infinity)).x, 0)
    }

    // MARK: World changes

    func testTheChangeLogNamesTheBlocksThatChanged() {
        var log = WorldChangeLog(everything: false)
        XCTAssertTrue(log.isEmpty)
        let a = BlockData(name: "A")
        log.note(.insert(a))
        log.note(.update(a))
        log.note(.environment(.default))
        XCTAssertEqual(log.blocks, [a.id])
        XCTAssertFalse(log.everything)
        let taken = log.take()
        XCTAssertEqual(taken.blocks, [a.id])
        XCTAssertTrue(log.isEmpty)
        // A removed block is named too, for the renderer to take it (and
        // what hangs from it) away; hanging one elsewhere needs a full look.
        log.note(.remove(blockID: a.id))
        XCTAssertEqual(log.removed, [a.id])
        XCTAssertFalse(log.everything)
        XCTAssertFalse(log.isEmpty)
        XCTAssertEqual(log.take().removed, [a.id])
        XCTAssertTrue(log.removed.isEmpty)
        log.note(.reparent(blockID: a.id, newParent: nil))
        XCTAssertTrue(log.everything)
        XCTAssertTrue(log.blocks.isEmpty)
        _ = log.take()
        // Too many changes at once: a full look is quicker.
        for _ in 0...WorldChangeLog.limit { log.note(block: UUID()) }
        XCTAssertTrue(log.everything)
        // A new log has not seen anything yet.
        XCTAssertTrue(WorldChangeLog().everything)
    }

    func testTheInboxAsksForOneDrainPerBurst() {
        let inbox = WorldDeltaInbox()
        let block = BlockData(name: "A")
        XCTAssertTrue(inbox.add(.insert(block)))
        XCTAssertFalse(inbox.add(.update(block)))
        XCTAssertFalse(inbox.add(.remove(blockID: block.id)))
        let first = inbox.take()
        XCTAssertEqual(first.count, 3)
        if case .insert = first[0] {} else { XCTFail("oldest first") }
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertTrue(inbox.add(.update(block)))
        XCTAssertEqual(inbox.take().count, 1)
        XCTAssertTrue(inbox.take().isEmpty)
    }

    func testTheTransformInboxKeepsEachPlayersNewestPosition() {
        let inbox = TransformInbox()
        let a = PeerID(), b = PeerID()
        XCTAssertTrue(inbox.add(PlayerTransformPayload(peerID: a, position: Vec3(1, 0, 0), yawDegrees: 0)))
        XCTAssertFalse(inbox.add(PlayerTransformPayload(peerID: b, position: Vec3(5, 0, 0), yawDegrees: 0)))
        XCTAssertFalse(inbox.add(PlayerTransformPayload(peerID: a, position: Vec3(2, 0, 0), yawDegrees: 90)))
        let taken = inbox.take()
        XCTAssertEqual(taken.map(\.peerID), [a, b])
        XCTAssertEqual(taken[0].position, Vec3(2, 0, 0))
        XCTAssertTrue(inbox.take().isEmpty)
    }

    func testThrottledPublishingHappensAtMostTenTimesASecond() {
        func wait(_ decision: PublishThrottle.Decision) -> Double? {
            if case let .after(seconds) = decision { return seconds }
            return nil
        }
        var throttle = PublishThrottle(interval: 0.1)
        XCTAssertEqual(throttle.changed(at: 1.0), .now)
        XCTAssertEqual(wait(throttle.changed(at: 1.02)) ?? -1, 0.08, accuracy: 1e-9)
        XCTAssertEqual(throttle.changed(at: 1.05), .alreadyScheduled)
        throttle.published(at: 1.1)
        XCTAssertEqual(wait(throttle.changed(at: 1.15)) ?? -1, 0.05, accuracy: 1e-9)
        throttle.published(at: 1.2)
        XCTAssertEqual(throttle.changed(at: 1.5), .now)
    }

    // MARK: The governor

    private func run(_ governor: inout FrameRateGovernor, fps: Double, seconds: Double) -> [GraphicsProfile.Level] {
        var changes: [GraphicsProfile.Level] = []
        for _ in 0..<Int(fps * seconds) {
            if let level = governor.record(frameTime: 1 / fps) { changes.append(level) }
        }
        return changes
    }

    func testA45FpsGameGivesUpAFewPixelsBeforeAnything() {
        var governor = FrameRateGovernor()
        XCTAssertEqual(run(&governor, fps: 45, seconds: 2.5), [])
        XCTAssertEqual(governor.resolutionFactor, 0.9, accuracy: 0.001)
        XCTAssertEqual(run(&governor, fps: 45, seconds: 10), [])
        XCTAssertEqual(governor.level, .high)
        XCTAssertEqual(governor.resolutionFactor, FrameRateGovernor.lowestResolutionFactor, accuracy: 0.001)
        // Smooth again: the pixels come back before the level would change.
        XCTAssertEqual(run(&governor, fps: 60, seconds: 15), [])
        XCTAssertEqual(governor.resolutionFactor, 1, accuracy: 0.001)
    }

    func testAVerySlowSecondStepsDownAtOnce() {
        var governor = FrameRateGovernor()
        XCTAssertEqual(run(&governor, fps: 12, seconds: 1.2), [.medium])
        XCTAssertEqual(run(&governor, fps: 12, seconds: 1.2), [.low])
        XCTAssertEqual(governor.resolutionFactor, 1)
    }

    func testAtTheLightestLevelOnlyPixelsAreLeftToGive() {
        var governor = FrameRateGovernor(startingAt: .lightest)
        XCTAssertEqual(run(&governor, fps: 24, seconds: 3.5), [])
        XCTAssertLessThan(governor.resolutionFactor, 1)
    }

    func testEveryLevelAnimatesAndLabelsLessThanTheOneAbove() {
        let levels = GraphicsProfile.Level.allCases.map(GraphicsProfile.profile(for:))
        for (lower, higher) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThan(lower.animationRange, higher.animationRange)
            XCTAssertLessThan(lower.labelLimit, higher.labelLimit)
        }
    }

    // MARK: The benchmark world

    func testTheBenchmarkWorldIsBusyAndItsScriptRuns() {
        let world = RenderBenchmark.world()
        XCTAssertEqual(world.blocks.map(\.position), RenderBenchmark.world().blocks.map(\.position), "the same town every time")
        XCTAssertGreaterThan(world.blocks.count, 2_500)
        XCTAssertEqual(world.validate(), [])
        let roots = world.blocks.filter { $0.tags.contains("walker") }
        XCTAssertEqual(roots.count, RenderBenchmark.walkerCount)
        XCTAssertTrue(roots.allSatisfy(RenderMerging.drawsNothing))
        let mergeable = world.blocks.filter { RenderMerging.canMerge($0, hasChildren: false) }.count
        XCTAssertGreaterThan(mergeable, world.blocks.count * 8 / 10, "most of it can be drawn as a few meshes")

        let game = GameRuntime(world: world, seed: 1)
        game.addPlayer(PlayerSnapshot(peerID: PeerID(), profile: .default))
        _ = game.handle(.roundStarted)
        var time = 0.0
        while time < 3 {
            time += 0.1
            _ = game.advance(to: time)
        }
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        let moved = game.world.blocks.filter { $0.tags.contains("walker") }
        XCTAssertNotEqual(moved.map(\.position), roots.map(\.position), "the characters walk")
        let tiles = game.world.blocks.filter { $0.tags.contains("disco") }
        XCTAssertEqual(tiles.count, RenderBenchmark.discoTiles)
        XCTAssertNotEqual(tiles.first?.color, ColorRGBA(hex: "#A855F7"), "the dance floor changes colour")
    }
}

/// Finding blocks by id and keeping the index up to date without reading
/// every block after each change.
final class BlockOrderTests: XCTestCase {

    private func world(_ count: Int) -> WorldDocument {
        var world = WorldDocument(name: "Lookup")
        world.blocks = (0..<count).map { BlockData(name: "B\($0)", transform: Transform3D(position: Vec3(Float($0), 0, 0))) }
        return world
    }

    func testBlocksAreFoundByIdThroughEveryKindOfChange() {
        var world = world(200)
        let ids = world.blocks.map(\.id)
        for (order, id) in ids.enumerated() { XCTAssertEqual(world.index(of: id), order) }
        XCTAssertNil(world.index(of: UUID()))

        // Added one at a time.
        var added: [UUID] = []
        for i in 0..<50 {
            let block = BlockData(name: "New \(i)")
            added.append(block.id)
            world.insert(block)
            XCTAssertEqual(world.index(of: block.id), world.blocks.count - 1)
        }
        XCTAssertEqual(world.index(of: added[10]), 210)

        // Removed: everything after it moves up.
        world.remove(id: ids[5])
        XCTAssertNil(world.index(of: ids[5]))
        XCTAssertEqual(world.index(of: ids[6]), 5)
        XCTAssertEqual(world.index(of: added[49]), 248)

        // A copy goes its own way; both still find their own blocks.
        var copy = world
        let late = BlockData(name: "Only in the copy")
        copy.insert(late)
        world.remove(id: ids[0])
        XCTAssertEqual(copy.index(of: late.id), copy.blocks.count - 1)
        XCTAssertNil(world.index(of: late.id))
        XCTAssertEqual(world.index(of: ids[1]), 0)
        XCTAssertEqual(copy.index(of: ids[1]), 1)

        // Replaced wholesale.
        world.blocks.reverse()
        XCTAssertEqual(world.index(of: ids[1]), world.blocks.count - 1)
    }

    func testTheIndexFollowsChangesMadeOneAtATime() {
        var world = world(300)
        let cache = WorldIndexCache()
        _ = cache.index(for: world)
        let id = world.blocks[120].id
        for step in 1...40 {
            world.mutate(id: id) { $0.position = Vec3(0, Float(step), 0) }
            XCTAssertEqual(cache.index(for: world).entry(for: id)?.position, Vec3(0, Float(step), 0))
        }
        let block = BlockData(name: "Late", transform: Transform3D(position: Vec3(9, 9, 9)))
        world.insert(block)
        XCTAssertEqual(cache.index(for: world).entry(for: block.id)?.position, Vec3(9, 9, 9))
        // A copy that went another way is not mistaken for this one.
        var other = self.world(300)
        other.mutate(id: other.blocks[3].id) { $0.position = Vec3(1, 2, 3) }
        XCTAssertEqual(cache.index(for: other).entry(for: other.blocks[3].id)?.position, Vec3(1, 2, 3))
        XCTAssertNil(cache.index(for: other).entry(for: id))
    }

    func testACopyCanBeKeptInStepWithTheBlocksThatChanged() {
        var world = world(100)
        let start = world.blockRevision.value
        XCTAssertEqual(world.blocksChanged(since: start), [])
        world.mutate(id: world.blocks[40].id) { $0.color.r = 0 }
        world.insert(BlockData(name: "New"))
        world.mutate(id: world.blocks[3].id) { $0.color.g = 0 }
        world.mutate(id: world.blocks[40].id) { $0.color.b = 0 }
        XCTAssertEqual(world.blocksChanged(since: start), [3, 40, 100])
        world.remove(id: world.blocks[0].id)
        XCTAssertNil(world.blocksChanged(since: start), "a removal is not written down")
    }

    func testTheJournalOnlyAnswersForItsOwnPast() {
        var journal = BlockJournal()
        journal.note(order: 4, from: 10, to: 11)
        journal.note(order: 7, from: 11, to: 12)
        XCTAssertEqual(journal.orders(since: 10).map(Array.init), [4, 7])
        XCTAssertEqual(journal.orders(since: 11).map(Array.init), [7])
        XCTAssertEqual(journal.orders(since: 12).map(Array.init), [])
        XCTAssertNil(journal.orders(since: 9))
        // A change that does not follow on starts again.
        journal.note(order: 1, from: 20, to: 21)
        XCTAssertNil(journal.orders(since: 11))
        XCTAssertEqual(journal.orders(since: 20).map(Array.init), [1])
        for step in 0..<(BlockJournal.capacity * 2) {
            journal.note(order: step, from: UInt64(21 + step), to: UInt64(22 + step))
        }
        XCTAssertNil(journal.orders(since: 20), "the oldest are let go")
        XCTAssertEqual(journal.orders(since: UInt64(21 + BlockJournal.capacity * 2)).map(Array.init), [])
    }
}

final class MovedBlockTests: XCTestCase {
    func testABlockThatOnlyMovedIsToldApart() {
        let block = BlockData(name: "Walker")
        var moved = block
        moved.position.x += 1
        XCTAssertTrue(RenderMerging.onlyMoved(block, moved))
        XCTAssertFalse(RenderMerging.onlyMoved(block, block), "not moved at all")
        var painted = moved
        painted.color.g = 0
        XCTAssertFalse(RenderMerging.onlyMoved(block, painted), "moved and painted")
        var turned = block
        turned.rotationDegrees = Vec3(0, 90, 0)
        XCTAssertTrue(RenderMerging.onlyMoved(block, turned))
    }
}
