import XCTest
@testable import AbloxCore

/// Task 4 — the no-code gimmick engine.
final class GimmickTests: XCTestCase {

    private let alice = PeerID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private let bob = PeerID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    private func snapshot(_ peer: PeerID, name: String) -> PlayerSnapshot {
        PlayerSnapshot(peerID: peer, profile: AvatarProfile(displayName: name))
    }

    private func machine(with extra: [BlockData], startTime: Double = 0) -> EventMachine {
        var world = WorldDocument.blank()
        world.blocks.append(contentsOf: extra)
        var machine = EventMachine(world: world, startTime: startTime)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        _ = machine.handle(.roundStarted)
        return machine
    }

    private func bounceSpeed(in effects: [EventMachine.Effect]) -> Float? {
        effects.compactMap { effect -> Float? in
            if case let .bouncePlayer(speed) = effect.action { return speed }
            return nil
        }.first
    }

    // MARK: Bounce

    func testBounceLaunchesTheTriggeringPlayer() {
        var pad = BlockData(name: "Trampoline", behavior: .bounce)
        pad.gimmick.bounceSpeed = 18
        var m = machine(with: [pad])

        let effects = m.handle(.touched(peer: alice, blockID: pad.id))
        XCTAssertEqual(bounceSpeed(in: effects), 18)

        // Personal: nobody else gets launched.
        let bounce = effects.first { if case .bouncePlayer = $0.action { return true }; return false }
        XCTAssertEqual(bounce?.targetPeerID, alice)
    }

    func testBounceIsHeldOffByItsCooldown() {
        var pad = BlockData(name: "Trampoline", behavior: .bounce)
        pad.gimmick.cooldown = 1.5
        var m = machine(with: [pad])

        XCTAssertNotNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: pad.id))))
        // Contact is reported every collision step while standing on it.
        XCTAssertNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: pad.id))))
        XCTAssertNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: pad.id))))

        _ = m.advance(to: 2.0)
        XCTAssertNotNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: pad.id))),
                        "the pad should work again once the cooldown elapses")
    }

    func testCooldownIsPerBlockNotGlobal() {
        let a = BlockData(name: "Pad A", behavior: .bounce)
        let b = BlockData(name: "Pad B", behavior: .bounce)
        var m = machine(with: [a, b])

        XCTAssertNotNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: a.id))))
        XCTAssertNotNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: b.id))),
                        "bouncing on one pad must not disable every other pad")
    }

    func testBounceCooldownIsSharedBetweenPlayers() {
        // The cooldown belongs to the block, not to the player: two people on
        // one pad should not double-fire it.
        var pad = BlockData(name: "Pad", behavior: .bounce)
        pad.gimmick.cooldown = 1.5
        var m = machine(with: [pad])
        m.addPlayer(snapshot(bob, name: "Bob"))

        XCTAssertNotNil(bounceSpeed(in: m.handle(.touched(peer: alice, blockID: pad.id))))
        XCTAssertNil(bounceSpeed(in: m.handle(.touched(peer: bob, blockID: pad.id))))
    }

    // MARK: Disappear

    func testDisappearingPlatformVanishesThenReturns() {
        var platform = BlockData(name: "Trapdoor", behavior: .disappear)
        platform.gimmick.disappearDelay = 0.3
        platform.gimmick.respawnDelay = 3.0
        var m = machine(with: [platform])

        // Stepping on it changes nothing immediately — the grace period is
        // the trap.
        _ = m.handle(.touched(peer: alice, blockID: platform.id))
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, true)
        XCTAssertEqual(m.world.block(id: platform.id)?.hasCollision, true)

        // It goes after the delay.
        let vanish = m.advance(to: 0.4)
        XCTAssertTrue(vanish.contains { $0.action == .setVisible(blockID: platform.id, visible: false) })
        XCTAssertTrue(vanish.contains { $0.action == .setCollision(blockID: platform.id, enabled: false) })
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, false)
        XCTAssertEqual(m.world.block(id: platform.id)?.hasCollision, false,
                       "a vanished platform must stop holding the player up")

        // Still gone partway through.
        XCTAssertTrue(m.advance(to: 2.0).isEmpty)
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, false)

        // And back.
        let restore = m.advance(to: 3.5)
        XCTAssertTrue(restore.contains { $0.action == .setVisible(blockID: platform.id, visible: true) })
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, true)
        XCTAssertEqual(m.world.block(id: platform.id)?.hasCollision, true)
    }

    func testRepeatedStepsDoNotStackRestores() {
        var platform = BlockData(name: "Trapdoor", behavior: .disappear)
        platform.gimmick.cooldown = 0.1
        var m = machine(with: [platform])

        // Step on it repeatedly while it is mid-cycle.
        _ = m.handle(.touched(peer: alice, blockID: platform.id))
        _ = m.advance(to: 0.2)
        _ = m.handle(.touched(peer: alice, blockID: platform.id))
        _ = m.advance(to: 0.4)

        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, false)

        // One restore, not several — and it must actually come back.
        _ = m.advance(to: 10)
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, true)
    }

    func testDisappearStateIsVisibleToLateJoiners() {
        // The document is mutated alongside the broadcast, so a world snapshot
        // sent mid-cycle already has the platform missing.
        let platform = BlockData(name: "Trapdoor", behavior: .disappear)
        var m = machine(with: [platform])
        _ = m.handle(.touched(peer: alice, blockID: platform.id))
        _ = m.advance(to: 0.5)
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, false)
    }

    // MARK: Teleport

    func testTeleportMovesThePlayerToItsTarget() {
        let destination = BlockData(
            name: "Exit",
            transform: Transform3D(position: Vec3(40, 6, -12), scale: Vec3(2, 1, 2))
        )
        var pad = BlockData(name: "Warp", behavior: .teleport)
        pad.gimmick.teleportTargetID = destination.id
        var m = machine(with: [pad, destination])

        let effects = m.handle(.touched(peer: alice, blockID: pad.id))
        let landing = effects.compactMap { effect -> Vec3? in
            if case let .teleportPlayer(to) = effect.action { return to }
            return nil
        }.first

        let arrival = try? XCTUnwrap(landing)
        XCTAssertEqual(arrival?.x ?? 0, 40, accuracy: 1e-3)
        XCTAssertEqual(arrival?.z ?? 0, -12, accuracy: 1e-3)
        XCTAssertGreaterThan(arrival?.y ?? 0, 6, "the player should arrive above the target, not inside it")
    }

    func testTeleportWithNoTargetIsInert() {
        let pad = BlockData(name: "Warp", behavior: .teleport)
        var m = machine(with: [pad])
        XCTAssertTrue(m.handle(.touched(peer: alice, blockID: pad.id)).isEmpty,
                      "an unconfigured pad must do nothing rather than drop the player at the origin")
    }

    func testTeleportToADeletedBlockIsInert() {
        var pad = BlockData(name: "Warp", behavior: .teleport)
        pad.gimmick.teleportTargetID = UUID()
        var m = machine(with: [pad])
        XCTAssertTrue(m.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
    }

    func testTeleportToItselfIsInert() {
        var pad = BlockData(name: "Warp", behavior: .teleport)
        pad.gimmick.teleportTargetID = pad.id
        var m = machine(with: [pad])
        XCTAssertTrue(m.handle(.touched(peer: alice, blockID: pad.id)).isEmpty,
                      "a self-referential pad would teleport the player onto the pad, firing forever")
    }

    // MARK: Collision contract

    func testBouncyAndDisappearingBlocksAreSolid() {
        // You have to be able to stand on them.
        var world = WorldDocument()
        world.blocks = [
            BlockData(name: "Floor", transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(40, 1, 40))),
            BlockData(name: "Pad", transform: Transform3D(position: Vec3(0, 0.25, 0), scale: Vec3(4, 0.5, 4)), behavior: .bounce)
        ]
        var position = Vec3(0, 2, 0)
        var velocity = Vec3(0, -8, 0)
        var landedOnPad = false
        var grounded = false
        for _ in 0..<120 {
            let step = WorldCollider.resolve(
                position: position, velocity: velocity, world: world, deltaTime: 1.0 / 60
            )
            position = step.position
            velocity = step.velocity
            if step.touchedBlockIDs.contains(world.blocks[1].id) { landedOnPad = true }
            if step.isGrounded { grounded = true; break }
        }
        XCTAssertTrue(landedOnPad, "the player should come to rest on the pad and report it")
        XCTAssertTrue(grounded, "a bouncy block has to be something you can stand on")
        XCTAssertEqual(position.y, 0.5, accuracy: 0.06, "resting on the pad's top face")
    }

    func testTeleportPadsAreWalkThrough() {
        var world = WorldDocument()
        world.blocks = [
            BlockData(name: "Floor", transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(40, 1, 40))),
            BlockData(name: "Warp", transform: Transform3D(position: Vec3(3, 0.5, 0), scale: Vec3(2, 1, 2)), behavior: .teleport)
        ]
        var position = Vec3(0, 0, 0)
        for _ in 0..<120 {
            position = WorldCollider.resolve(
                position: position, velocity: Vec3(5, 0, 0), world: world, deltaTime: 1.0 / 60
            ).position
        }
        XCTAssertGreaterThan(position.x, 4, "a warp pad should not be a wall")
    }

    // MARK: Round lifecycle

    func testRestartingTheRoundClearsGimmickState() {
        var platform = BlockData(name: "Trapdoor", behavior: .disappear)
        platform.gimmick.cooldown = 1.5
        var m = machine(with: [platform])

        _ = m.handle(.touched(peer: alice, blockID: platform.id))
        _ = m.advance(to: 0.5)
        XCTAssertEqual(m.world.block(id: platform.id)?.isVisible, false)

        _ = m.handle(.roundStarted)
        // The cooldown is cleared, so the platform is immediately usable again.
        _ = m.handle(.touched(peer: alice, blockID: platform.id))
        XCTAssertNotNil(m.world.block(id: platform.id))
    }

    // MARK: Serialization

    func testGimmickSettingsRoundTrip() throws {
        var block = BlockData(name: "Warp", behavior: .teleport)
        block.gimmick = GimmickSettings(
            bounceSpeed: 21, disappearDelay: 0.5, respawnDelay: 4, teleportTargetID: UUID(), cooldown: 2
        )
        let restored = try JSONDecoder().decode(BlockData.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(restored.gimmick, block.gimmick)
    }

    func testOlderWorldsWithoutGimmickSettingsStillLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","behavior":"bounce"}
        """
        let block = try JSONDecoder().decode(BlockData.self, from: Data(json.utf8))
        XCTAssertEqual(block.behavior, .bounce)
        XCTAssertEqual(block.gimmick, .default, "a world from before gimmick tuning gets the defaults")
    }

    func testBouncePlayerActionRoundTrips() throws {
        let action = EventAction.bouncePlayer(speed: 16.5)
        let restored = try JSONDecoder().decode(EventAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(restored, action)
    }

    func testEveryGimmickIsFlaggedForTouchDetection() {
        for behavior in BlockBehavior.allCases where behavior.isGimmick {
            XCTAssertTrue(behavior.needsTouchDetection, "\(behavior) must be reported on contact")
        }
    }
}
