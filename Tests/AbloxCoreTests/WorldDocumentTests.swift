import XCTest
@testable import AbloxCore

final class WorldDocumentTests: XCTestCase {

    /// parent → child → grandchild, each offset 1 unit along +X.
    private func makeChain() -> (WorldDocument, UUID, UUID, UUID) {
        var world = WorldDocument(name: "Chain")
        let parent = BlockData(name: "Parent", transform: Transform3D(position: Vec3(1, 0, 0)))
        var child = BlockData(name: "Child", transform: Transform3D(position: Vec3(1, 0, 0)))
        child.parentID = parent.id
        var grandchild = BlockData(name: "Grandchild", transform: Transform3D(position: Vec3(1, 0, 0)))
        grandchild.parentID = child.id
        world.blocks = [parent, child, grandchild]
        return (world, parent.id, child.id, grandchild.id)
    }

    // MARK: Hierarchy

    func testWorldTransformAccumulatesThroughAncestors() {
        let (world, _, _, grandchildID) = makeChain()
        XCTAssertEqual(world.worldPosition(of: grandchildID).x, 3, accuracy: 1e-5)
    }

    func testWorldTransformAppliesParentRotation() {
        var world = WorldDocument()
        let parent = BlockData(name: "P", transform: Transform3D(position: .zero, rotation: .yaw(degrees: 90)))
        var child = BlockData(name: "C", transform: Transform3D(position: Vec3(0, 0, -2)))
        child.parentID = parent.id
        world.blocks = [parent, child]

        let p = world.worldPosition(of: child.id)
        XCTAssertEqual(p.x, -2, accuracy: 1e-4)
        XCTAssertEqual(p.z, 0, accuracy: 1e-4)
    }

    func testAncestorsAreNearestFirst() {
        let (world, parentID, childID, grandchildID) = makeChain()
        let ancestors = world.ancestors(of: grandchildID).map(\.id)
        XCTAssertEqual(ancestors, [childID, parentID])
    }

    func testSubtreeIncludesSelfAndDescendants() {
        let (world, parentID, childID, grandchildID) = makeChain()
        XCTAssertEqual(Set(world.subtree(of: parentID).map(\.id)), [parentID, childID, grandchildID])
        XCTAssertEqual(Set(world.subtree(of: childID).map(\.id)), [childID, grandchildID])
        XCTAssertTrue(world.subtree(of: UUID()).isEmpty)
    }

    func testChildrenAndRoots() {
        let (world, parentID, childID, _) = makeChain()
        XCTAssertEqual(world.rootBlocks.map(\.id), [parentID])
        XCTAssertEqual(world.children(of: parentID).map(\.id), [childID])
    }

    func testAncestorsTerminatesOnCycle() {
        // A malformed document must not hang the Explorer.
        var world = WorldDocument()
        var a = BlockData(name: "A")
        var b = BlockData(name: "B")
        a.parentID = b.id
        b.parentID = a.id
        world.blocks = [a, b]
        XCTAssertLessThanOrEqual(world.ancestors(of: a.id).count, 2)
        XCTAssertFalse(world.validate().isEmpty)
        XCTAssertTrue(world.validate().contains { $0.kind == .parentCycle })
    }

    // MARK: Reparenting

    func testReparentRejectsCycles() {
        var (world, parentID, childID, grandchildID) = makeChain()
        XCTAssertFalse(world.setParent(of: parentID, to: childID), "a parent cannot become its own descendant's child")
        XCTAssertFalse(world.setParent(of: parentID, to: grandchildID))
        XCTAssertFalse(world.setParent(of: parentID, to: parentID), "self-parenting is a cycle too")
        XCTAssertEqual(world.block(id: parentID)?.parentID, nil)
    }

    func testReparentToRootSucceeds() {
        var (world, _, _, grandchildID) = makeChain()
        XCTAssertTrue(world.setParent(of: grandchildID, to: nil))
        XCTAssertNil(world.block(id: grandchildID)?.parentID)
        XCTAssertEqual(world.worldPosition(of: grandchildID).x, 1, accuracy: 1e-5)
    }

    func testReparentToUnknownBlockFails() {
        var (world, _, childID, _) = makeChain()
        XCTAssertFalse(world.setParent(of: childID, to: UUID()))
    }

    // MARK: Removal

    func testRemoveTakesWholeSubtree() {
        var (world, parentID, _, _) = makeChain()
        let removed = world.remove(id: parentID)
        XCTAssertEqual(removed.count, 3)
        XCTAssertTrue(world.blocks.isEmpty, "children must not be orphaned to the world origin")
    }

    func testRemoveDropsRulesThatReferenceTheBlock() {
        var (world, _, childID, _) = makeChain()
        world.rules = [
            EventRule(name: "keep", trigger: .worldStart, actions: [.playSound(name: "a")]),
            EventRule(name: "drop", trigger: .blockTouched(blockID: childID), actions: [])
        ]
        world.remove(id: childID)
        XCTAssertEqual(world.rules.map(\.name), ["keep"])
    }

    func testRemoveUnknownIDIsHarmless() {
        var (world, _, _, _) = makeChain()
        XCTAssertTrue(world.remove(id: UUID()).isEmpty)
        XCTAssertEqual(world.blocks.count, 3)
    }

    // MARK: Bounds

    func testWorldBoundsOfRotatedBlockEnclosesIt() {
        var world = WorldDocument()
        // A long thin bar, yawed 45°: the AABB must grow on both X and Z.
        let block = BlockData(
            name: "Bar",
            shape: .box,
            transform: Transform3D(position: .zero, rotation: .yaw(degrees: 45), scale: Vec3(10, 1, 1))
        )
        world.blocks = [block]
        let bounds = world.worldBounds(of: block.id)!
        let expected = (10 / 2 + 1 / 2) * (2 as Float).squareRoot() / 2 * 2
        XCTAssertEqual(bounds.size.x, expected, accuracy: 0.05)
        XCTAssertEqual(bounds.size.z, expected, accuracy: 0.05)
    }

    func testEmptyWorldHasNoBounds() {
        XCTAssertNil(WorldDocument().worldBounds)
    }

    // MARK: Spawning

    func testSpawnPositionSitsAboveTheSpawnBlock() {
        var world = WorldDocument()
        let spawn = BlockData.preset(.spawn, at: Vec3(5, 10, -3))
        world.blocks = [spawn]
        let p = world.spawnPosition(forPlayerIndex: 0)
        XCTAssertEqual(p.x, 5, accuracy: 1e-5)
        XCTAssertEqual(p.z, -3, accuracy: 1e-5)
        XCTAssertGreaterThan(p.y, 10, "players must start above the pad, not inside it")
    }

    func testSpawnPositionsCycleAndFallBack() {
        var world = WorldDocument()
        world.blocks = [
            BlockData.preset(.spawn, at: Vec3(0, 0, 0)),
            BlockData.preset(.spawn, at: Vec3(10, 0, 0))
        ]
        XCTAssertEqual(world.spawnPosition(forPlayerIndex: 0).x, 0, accuracy: 1e-5)
        XCTAssertEqual(world.spawnPosition(forPlayerIndex: 1).x, 10, accuracy: 1e-5)
        XCTAssertEqual(world.spawnPosition(forPlayerIndex: 2).x, 0, accuracy: 1e-5, "index wraps")

        let empty = WorldDocument()
        XCTAssertEqual(empty.spawnPosition(forPlayerIndex: 0), Vec3(0, 2, 0))
    }

    // MARK: Naming

    func testUniqueNameAvoidsCollisions() {
        var world = WorldDocument()
        world.blocks = [BlockData(name: "Block"), BlockData(name: "Block 2")]
        XCTAssertEqual(world.uniqueName(basedOn: "Block"), "Block 3")
        XCTAssertEqual(world.uniqueName(basedOn: "Ramp"), "Ramp")
    }

    // MARK: Validation

    func testValidationFlagsDanglingParentAndRuleTarget() {
        var world = WorldDocument()
        var orphan = BlockData(name: "Orphan")
        orphan.parentID = UUID()
        world.blocks = [orphan]
        world.rules = [EventRule(name: "ghost", trigger: .blockTouched(blockID: UUID()), actions: [])]

        let kinds = Set(world.validate().map(\.kind))
        XCTAssertTrue(kinds.contains(.danglingParent))
        XCTAssertTrue(kinds.contains(.danglingRuleTarget))
        XCTAssertTrue(kinds.contains(.noSpawnPoint))
    }

    func testValidationFlagsDegenerateScale() {
        var world = WorldDocument()
        world.blocks = [BlockData(name: "Flat", transform: Transform3D(scale: Vec3(1, 0, 1)))]
        XCTAssertTrue(world.validate().contains { $0.kind == .degenerateScale })
    }

    func testStarterWorldIsValidApartFromNothing() {
        let world = WorldDocument.starter()
        XCTAssertTrue(world.validate().isEmpty, "the starter world must open clean: \(world.validate())")
        XCTAssertFalse(world.spawnBlocks.isEmpty)
        XCTAssertFalse(world.rules.isEmpty)
    }

    func testBlankWorldIsValid() {
        XCTAssertTrue(WorldDocument.blank().validate().isEmpty)
    }

    // MARK: Serialization

    func testWorldRoundTripsThroughJSON() throws {
        let world = WorldDocument.starter(named: "Round Trip", author: "Taro")
        let restored = try WorldDocument.decoded(from: world.encodedForFile())

        XCTAssertEqual(restored.id, world.id)
        XCTAssertEqual(restored.name, "Round Trip")
        XCTAssertEqual(restored.authorName, "Taro")
        XCTAssertEqual(restored.blocks.count, world.blocks.count)
        XCTAssertEqual(restored.rules, world.rules)
        XCTAssertEqual(restored.environment, world.environment)
        // Dates survive as ISO-8601, to the second.
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, world.createdAt.timeIntervalSince1970, accuracy: 1)
    }

    func testWireEncodingIsSmallerThanFileEncoding() throws {
        let world = WorldDocument.starter()
        XCTAssertLessThan(try world.encodedForWire().count, try world.encodedForFile().count)
    }

    func testNewerSchemaIsRejectedWithAReadableMessage() throws {
        var world = WorldDocument.blank()
        world.schemaVersion = WorldDocument.currentSchemaVersion + 1
        let data = try world.encodedForFile()

        XCTAssertThrowsError(try WorldDocument.decoded(from: data)) { error in
            guard case let WorldDocumentError.unsupportedSchema(found, supported) = error else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
            XCTAssertEqual(found, WorldDocument.currentSchemaVersion + 1)
            XCTAssertEqual(supported, WorldDocument.currentSchemaVersion)
            XCTAssertTrue(error.localizedDescription.contains("newer version"), error.localizedDescription)
        }
    }

    func testBlockDecodesLeniently() throws {
        // A world written by an older build that predates `behavior`/`tags`.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","transform":{"position":{"x":1,"y":2,"z":3},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"color":{"r":1,"g":0,"b":0,"a":1}}
        """
        let block = try JSONDecoder().decode(BlockData.self, from: Data(json.utf8))
        XCTAssertEqual(block.name, "Legacy")
        XCTAssertEqual(block.shape, .box, "missing fields fall back to the same defaults init uses")
        XCTAssertEqual(block.behavior, .none)
        XCTAssertTrue(block.tags.isEmpty)
        XCTAssertTrue(block.isAnchored)
        XCTAssertEqual(block.position, Vec3(1, 2, 3))
    }

    // MARK: Deltas

    func testInsertDeltaIsIdempotent() {
        var world = WorldDocument.blank()
        let block = BlockData(name: "Dup")
        XCTAssertTrue(WorldDelta.insert(block).apply(to: &world))
        let countAfterFirst = world.blocks.count
        XCTAssertTrue(WorldDelta.insert(block).apply(to: &world), "a replayed insert updates rather than duplicating")
        XCTAssertEqual(world.blocks.count, countAfterFirst)
    }

    func testUpdateDeltaForMissingBlockIsRejected() {
        var world = WorldDocument.blank()
        XCTAssertFalse(WorldDelta.update(BlockData(name: "Ghost")).apply(to: &world))
    }

    func testDeltasApplyEnvironmentAndRules() {
        var world = WorldDocument.blank()
        var env = EnvironmentSettings.default
        env.gravity = -3
        XCTAssertTrue(WorldDelta.environment(env).apply(to: &world))
        XCTAssertEqual(world.environment.gravity, -3)

        let rule = EventRule(name: "new", trigger: .worldStart, actions: [])
        XCTAssertTrue(WorldDelta.rulesReplaced([rule]).apply(to: &world))
        XCTAssertEqual(world.rules, [rule])
    }

    // MARK: Tags

    func testTagMatchingIsCaseInsensitive() {
        let block = BlockData(name: "Coin", tags: ["Coin", "Shiny"])
        XCTAssertTrue(block.hasTag("coin"))
        XCTAssertTrue(block.hasTag("COIN"))
        XCTAssertFalse(block.hasTag("coins"))
    }

    // MARK: Avatars

    func testGeneratedAvatarsAreDeterministicAndVaried() {
        let a = PeerID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        let b = PeerID(UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!)
        XCTAssertEqual(AvatarProfile.generated(for: a, name: "A"), AvatarProfile.generated(for: a, name: "A"))
        // Different peers should not all look identical.
        let profiles = (0..<20).map { _ in AvatarProfile.generated(for: PeerID(), name: "x") }
        XCTAssertGreaterThan(Set(profiles.map(\.bodyColor.hexString)).count, 1)
        XCTAssertNotEqual(AvatarProfile.generated(for: a, name: "A").bodyColor,
                          AvatarProfile.generated(for: b, name: "B").bodyColor)
    }
}
