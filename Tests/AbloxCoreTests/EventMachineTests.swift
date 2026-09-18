import XCTest
@testable import AbloxCore

final class EventMachineTests: XCTestCase {

    private let alice = PeerID(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private let bob = PeerID(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    private func snapshot(_ peer: PeerID, name: String, at position: Vec3 = .zero) -> PlayerSnapshot {
        PlayerSnapshot(peerID: peer, profile: AvatarProfile(displayName: name), position: position)
    }

    /// A floor, a spawn pad, and whatever extra blocks the test needs.
    private func makeWorld(extra: [BlockData] = []) -> WorldDocument {
        var world = WorldDocument.blank()
        world.blocks.append(contentsOf: extra)
        return world
    }

    private func started(_ machine: inout EventMachine) {
        _ = machine.handle(.roundStarted)
    }

    // MARK: Built-in behaviours

    func testCollectibleAwardsPointsOnceAndHides() {
        let coin = BlockData(name: "Coin", behavior: .collectible, scoreValue: 10)
        var machine = EventMachine(world: makeWorld(extra: [coin]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        let first = machine.handle(.touched(peer: alice, blockID: coin.id))
        XCTAssertTrue(first.contains { $0.action == .setVisible(blockID: coin.id, visible: false) })
        XCTAssertTrue(first.contains { $0.action == .awardPoints(10) })
        XCTAssertEqual(machine.player(alice)?.score, 10)

        // Farming the same coin must do nothing.
        let second = machine.handle(.touched(peer: alice, blockID: coin.id))
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(machine.player(alice)?.score, 10)
    }

    func testCollectiblesAreTrackedPerPlayer() {
        let coin = BlockData(name: "Coin", behavior: .collectible, scoreValue: 5)
        var machine = EventMachine(world: makeWorld(extra: [coin]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        machine.addPlayer(snapshot(bob, name: "Bob"))
        started(&machine)

        _ = machine.handle(.touched(peer: alice, blockID: coin.id))
        let bobEffects = machine.handle(.touched(peer: bob, blockID: coin.id))

        XCTAssertFalse(bobEffects.isEmpty, "Bob has not collected this coin yet")
        XCTAssertEqual(machine.player(alice)?.score, 5)
        XCTAssertEqual(machine.player(bob)?.score, 5)
        XCTAssertEqual(machine.consumedBlocks(for: alice), [coin.id])
    }

    func testHazardTeleportsToRespawnAndDeductsPoints() {
        let lava = BlockData(name: "Lava", behavior: .hazard, scoreValue: 3)
        var machine = EventMachine(world: makeWorld(extra: [lava]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        let effects = machine.handle(.touched(peer: alice, blockID: lava.id))
        XCTAssertTrue(effects.contains { if case .teleportPlayer = $0.action { return true }; return false })
        XCTAssertTrue(effects.contains { $0.action == .awardPoints(-3) }, "scoreValue is a penalty on a hazard")
        XCTAssertEqual(machine.player(alice)?.score, -3)
        XCTAssertTrue(effects.allSatisfy { $0.targetPeerID == alice }, "a hazard is personal, not a broadcast")
    }

    func testCheckpointUpdatesRespawnAndIsNotRepeated() {
        let checkpoint = BlockData(
            name: "CP",
            transform: Transform3D(position: Vec3(20, 5, 0), scale: Vec3(2, 1, 2)),
            isAnchored: true,
            behavior: .checkpoint
        )
        var machine = EventMachine(world: makeWorld(extra: [checkpoint]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        let first = machine.handle(.touched(peer: alice, blockID: checkpoint.id))
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(machine.respawnPoint(for: alice).x, 20, accuracy: 1e-4)
        XCTAssertGreaterThan(machine.respawnPoint(for: alice).y, 5)

        let second = machine.handle(.touched(peer: alice, blockID: checkpoint.id))
        XCTAssertTrue(second.isEmpty, "standing on a checkpoint you already hold is not an event")
    }

    func testHazardAfterCheckpointReturnsToTheCheckpoint() throws {
        let checkpoint = BlockData(name: "CP", transform: Transform3D(position: Vec3(30, 0, 0)), behavior: .checkpoint)
        let lava = BlockData(name: "Lava", behavior: .hazard)
        var machine = EventMachine(world: makeWorld(extra: [checkpoint, lava]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        _ = machine.handle(.touched(peer: alice, blockID: checkpoint.id))
        let effects = machine.handle(.touched(peer: alice, blockID: lava.id))

        let destination = effects.compactMap { effect -> Vec3? in
            if case let .teleportPlayer(to) = effect.action { return to }
            return nil
        }.first
        XCTAssertEqual(try XCTUnwrap(destination).x, 30, accuracy: 1e-4)
    }

    func testGoalEndsTheRoundForEveryone() {
        let goal = BlockData(name: "Finish", behavior: .goal)
        var machine = EventMachine(world: makeWorld(extra: [goal]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        let effects = machine.handle(.touched(peer: alice, blockID: goal.id))
        XCTAssertTrue(machine.isRoundOver)
        let message = effects.compactMap { effect -> String? in
            if case let .endRound(message) = effect.action { return message }
            return nil
        }.first
        XCTAssertEqual(message, "Alice reached the goal!")
        XCTAssertNil(effects.first?.targetPeerID, "the end of the round is everyone's business")
    }

    func testNoEventsAfterTheRoundEnds() {
        let goal = BlockData(name: "Finish", behavior: .goal)
        let coin = BlockData(name: "Coin", behavior: .collectible, scoreValue: 10)
        var machine = EventMachine(world: makeWorld(extra: [goal, coin]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        _ = machine.handle(.touched(peer: alice, blockID: goal.id))
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: coin.id)).isEmpty)
        XCTAssertEqual(machine.player(alice)?.score, 0)

        // A fresh round clears everything.
        let restart = machine.handle(.roundStarted)
        XCTAssertFalse(machine.isRoundOver)
        XCTAssertTrue(restart.isEmpty, "the blank world has no worldStart rules")
        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: coin.id)).isEmpty)
    }

    func testInertBlocksProduceNothing() {
        let scenery = BlockData(name: "Rock", behavior: .none)
        var machine = EventMachine(world: makeWorld(extra: [scenery]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: scenery.id)).isEmpty)
    }

    func testTouchingAnUnknownBlockIsIgnored() {
        var machine = EventMachine(world: makeWorld())
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: UUID())).isEmpty)
    }

    // MARK: Authored rules

    func testWorldStartRuleFiresOnce() {
        var world = makeWorld()
        world.rules = [EventRule(name: "intro", trigger: .worldStart, actions: [.announce(message: "Go!", duration: 2)])]
        var machine = EventMachine(world: world)

        let effects = machine.handle(.roundStarted)
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(effects[0].action, .announce(message: "Go!", duration: 2))
    }

    func testTagTouchedRuleMatchesAnyTaggedBlock() {
        let coinA = BlockData(name: "A", behavior: .trigger, tags: ["coin"])
        let coinB = BlockData(name: "B", behavior: .trigger, tags: ["COIN"])
        let other = BlockData(name: "C", behavior: .trigger, tags: ["rock"])
        var world = makeWorld(extra: [coinA, coinB, other])
        world.rules = [EventRule(
            name: "sparkle",
            trigger: .tagTouched(tag: "coin"),
            actions: [.playSound(name: "ding")],
            cooldown: 0
        )]

        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: coinA.id)).isEmpty)
        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: coinB.id)).isEmpty, "tag match is case-insensitive")
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: other.id)).isEmpty)
    }

    func testCooldownSuppressesRapidRefiring() {
        let pad = BlockData(name: "Pad", behavior: .trigger)
        var world = makeWorld(extra: [pad])
        world.rules = [EventRule(
            name: "beep",
            trigger: .blockTouched(blockID: pad.id),
            actions: [.playSound(name: "beep")],
            cooldown: 1.0
        )]

        var machine = EventMachine(world: world, startTime: 0)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty, "still inside the cooldown")

        _ = machine.advance(to: 1.5)
        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty, "cooldown elapsed")
    }

    func testMaxFireCountIsHonoured() {
        let pad = BlockData(name: "Pad", behavior: .trigger)
        var world = makeWorld(extra: [pad])
        world.rules = [EventRule(
            name: "once",
            trigger: .blockTouched(blockID: pad.id),
            actions: [.announce(message: "only once", duration: 1)],
            maxFireCount: 1,
            cooldown: 0
        )]

        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
    }

    func testDisabledRulesNeverFire() {
        let pad = BlockData(name: "Pad", behavior: .trigger)
        var world = makeWorld(extra: [pad])
        world.rules = [EventRule(
            name: "off",
            isEnabled: false,
            trigger: .blockTouched(blockID: pad.id),
            actions: [.playSound(name: "x")],
            cooldown: 0
        )]
        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
    }

    func testSetVisibleRuleMirrorsIntoTheWorld() {
        let door = BlockData(name: "Door")
        let lever = BlockData(name: "Lever", behavior: .trigger)
        var world = makeWorld(extra: [door, lever])
        world.rules = [EventRule(
            name: "open",
            trigger: .blockTouched(blockID: lever.id),
            actions: [.setVisible(blockID: door.id, visible: false), .setCollision(blockID: door.id, enabled: false)],
            cooldown: 0
        )]

        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)
        _ = machine.handle(.touched(peer: alice, blockID: lever.id))

        // A player joining after the lever was pulled must see the open door.
        XCTAssertEqual(machine.world.block(id: door.id)?.isVisible, false)
        XCTAssertEqual(machine.world.block(id: door.id)?.hasCollision, false)
    }

    func testInstantTintMirrorsButAnimatedTintDoesNot() {
        let lamp = BlockData(name: "Lamp")
        let pad = BlockData(name: "Pad", behavior: .trigger)
        let red = ColorRGBA(hex: "#FF0000")!

        var instantWorld = makeWorld(extra: [lamp, pad])
        instantWorld.rules = [EventRule(name: "i", trigger: .blockTouched(blockID: pad.id), actions: [.tint(blockID: lamp.id, color: red, duration: 0)], cooldown: 0)]
        var instant = EventMachine(world: instantWorld)
        instant.addPlayer(snapshot(alice, name: "A"))
        started(&instant)
        _ = instant.handle(.touched(peer: alice, blockID: pad.id))
        XCTAssertEqual(instant.world.block(id: lamp.id)?.color, red)

        var animatedWorld = makeWorld(extra: [lamp, pad])
        animatedWorld.rules = [EventRule(name: "a", trigger: .blockTouched(blockID: pad.id), actions: [.tint(blockID: lamp.id, color: red, duration: 2)], cooldown: 0)]
        var animated = EventMachine(world: animatedWorld)
        animated.addPlayer(snapshot(alice, name: "A"))
        started(&animated)
        let effects = animated.handle(.touched(peer: alice, blockID: pad.id))
        XCTAssertNotEqual(animated.world.block(id: lamp.id)?.color, red, "an animated tint is the client's job")
        XCTAssertFalse(effects.isEmpty, "but it is still broadcast")
    }

    func testAwardPointsRuleNeedsATriggeringPlayer() {
        var world = makeWorld()
        world.rules = [EventRule(name: "bonus", trigger: .worldStart, actions: [.awardPoints(50)])]
        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))

        let effects = machine.handle(.roundStarted)
        XCTAssertTrue(effects.isEmpty, "worldStart has no triggering player, so there is nobody to award")
        XCTAssertEqual(machine.player(alice)?.score, 0)
    }

    func testScoreReachedChainsFromAnAward() {
        let coin = BlockData(name: "Coin", behavior: .collectible, scoreValue: 100)
        var world = makeWorld(extra: [coin])
        world.rules = [EventRule(
            name: "win",
            trigger: .scoreReached(score: 100),
            actions: [.endRound(message: "100 points!")],
            cooldown: 0
        )]

        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        let effects = machine.handle(.touched(peer: alice, blockID: coin.id))
        XCTAssertTrue(effects.contains { $0.action == .endRound(message: "100 points!") },
                      "collecting must cascade into the score rule")
        XCTAssertTrue(machine.isRoundOver)
    }

    // MARK: Timers

    func testTimerRuleFiresOnSchedule() {
        var world = makeWorld()
        world.rules = [EventRule(
            name: "tick",
            trigger: .timer(interval: 1.0),
            actions: [.playSound(name: "tick")],
            cooldown: 0
        )]
        var machine = EventMachine(world: world, startTime: 0)
        started(&machine)

        XCTAssertTrue(machine.advance(to: 0.5).isEmpty)
        XCTAssertFalse(machine.advance(to: 1.1).isEmpty)
        XCTAssertTrue(machine.advance(to: 1.5).isEmpty)
        XCTAssertFalse(machine.advance(to: 2.2).isEmpty)
    }

    func testTimerDoesNotFireBeforeTheRoundStarts() {
        var world = makeWorld()
        world.rules = [EventRule(name: "tick", trigger: .timer(interval: 0.1), actions: [.playSound(name: "t")], cooldown: 0)]
        var machine = EventMachine(world: world, startTime: 0)
        XCTAssertTrue(machine.advance(to: 10).isEmpty, "nothing runs until the round starts")
    }

    func testClockNeverRunsBackwards() {
        var machine = EventMachine(world: makeWorld(), startTime: 10)
        started(&machine)
        XCTAssertTrue(machine.advance(to: 5).isEmpty)
    }

    // MARK: Proximity

    func testProximityFiresOnEntryOnly() {
        let sensor = BlockData(name: "Sensor", transform: Transform3D(position: Vec3(10, 0, 0)), behavior: .trigger)
        var world = makeWorld(extra: [sensor])
        world.rules = [EventRule(
            name: "near",
            trigger: .proximity(blockID: sensor.id, radius: 3),
            actions: [.announce(message: "close", duration: 1)],
            cooldown: 0
        )]

        var machine = EventMachine(world: world, startTime: 0)
        machine.addPlayer(snapshot(alice, name: "Alice", at: Vec3(0, 0, 0)))
        started(&machine)

        XCTAssertTrue(machine.advance(to: 1).isEmpty, "still far away")

        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(9, 0, 0), yawDegrees: 0))
        XCTAssertFalse(machine.advance(to: 2).isEmpty, "entered the radius")

        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(10, 0, 0), yawDegrees: 0))
        XCTAssertTrue(machine.advance(to: 3).isEmpty, "still inside: entry fires once")
    }

    func testProximityHysteresisPreventsBoundaryChatter() {
        let sensor = BlockData(name: "Sensor", behavior: .trigger)
        var world = makeWorld(extra: [sensor])
        world.rules = [EventRule(
            name: "near",
            trigger: .proximity(blockID: sensor.id, radius: 10),
            actions: [.playSound(name: "ping")],
            cooldown: 0
        )]

        var machine = EventMachine(world: world, startTime: 0)
        machine.addPlayer(snapshot(alice, name: "Alice", at: Vec3(5, 0, 0)))
        started(&machine)
        XCTAssertFalse(machine.advance(to: 1).isEmpty)

        // Step just outside the radius but inside the 15% hysteresis band.
        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(10.5, 0, 0), yawDegrees: 0))
        _ = machine.advance(to: 2)
        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(9, 0, 0), yawDegrees: 0))
        XCTAssertTrue(machine.advance(to: 3).isEmpty, "wobbling on the edge must not re-fire")

        // Clearly outside, then back in: that is a genuine re-entry.
        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(50, 0, 0), yawDegrees: 0))
        _ = machine.advance(to: 4)
        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(0, 0, 0), yawDegrees: 0))
        XCTAssertFalse(machine.advance(to: 5).isEmpty)
    }

    func testProximityIgnoresHeight() {
        let sensor = BlockData(name: "Sensor", behavior: .trigger)
        var world = makeWorld(extra: [sensor])
        world.rules = [EventRule(name: "near", trigger: .proximity(blockID: sensor.id, radius: 2), actions: [.playSound(name: "p")], cooldown: 0)]

        var machine = EventMachine(world: world, startTime: 0)
        machine.addPlayer(snapshot(alice, name: "Alice", at: Vec3(0, 40, 0)))
        started(&machine)
        XCTAssertFalse(machine.advance(to: 1).isEmpty, "standing on a tall tower still counts as near")
    }

    // MARK: Kill plane

    func testFallingBelowTheKillPlaneRespawns() {
        var world = makeWorld()
        world.environment.killPlaneHeight = -10
        var machine = EventMachine(world: world, startTime: 0)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(0, -50, 0), yawDegrees: 0, velocity: Vec3(0, -30, 0)))
        let effects = machine.advance(to: 1)

        XCTAssertTrue(effects.contains { if case .teleportPlayer = $0.action { return true }; return false })
        XCTAssertGreaterThan(machine.player(alice)!.position.y, -10)
        XCTAssertEqual(machine.player(alice)!.velocity, .zero, "respawning must clear the fall velocity")
    }

    // MARK: Roster

    func testJoiningPlayerStartsAtASpawnPoint() {
        var world = WorldDocument.blank()
        world.blocks.append(BlockData.preset(.spawn, at: Vec3(7, 0, 7)))
        var machine = EventMachine(world: world)
        // A handshake carrying a stale position must not be trusted.
        machine.addPlayer(snapshot(alice, name: "Alice", at: Vec3(999, 999, 999)))
        XCTAssertNotEqual(machine.player(alice)?.position, Vec3(999, 999, 999))
    }

    func testRemovingAPlayerClearsTheirState() {
        let coin = BlockData(name: "Coin", behavior: .collectible, scoreValue: 1)
        var machine = EventMachine(world: makeWorld(extra: [coin]))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)
        _ = machine.handle(.touched(peer: alice, blockID: coin.id))

        machine.removePlayer(alice)
        XCTAssertNil(machine.player(alice))
        XCTAssertTrue(machine.consumedBlocks(for: alice).isEmpty)
    }

    func testRosterIsStablySorted() {
        var machine = EventMachine(world: makeWorld())
        machine.addPlayer(snapshot(bob, name: "Bob"))
        machine.addPlayer(snapshot(alice, name: "Alice"))
        XCTAssertEqual(machine.roster.map(\.profile.displayName), ["Alice", "Bob"])
    }

    func testTransformUpdateForUnknownPlayerIsIgnored() {
        var machine = EventMachine(world: makeWorld())
        machine.updateTransform(PlayerTransformPayload(peerID: alice, position: Vec3(1, 2, 3), yawDegrees: 0))
        XCTAssertNil(machine.player(alice))
    }

    // MARK: Live editing

    func testApplyingADeltaPrunesRuleBookkeeping() {
        let pad = BlockData(name: "Pad", behavior: .trigger)
        var world = makeWorld(extra: [pad])
        world.rules = [EventRule(
            name: "once",
            trigger: .blockTouched(blockID: pad.id),
            actions: [.playSound(name: "x")],
            maxFireCount: 1,
            cooldown: 0
        )]

        var machine = EventMachine(world: world)
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)
        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
        XCTAssertTrue(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)

        // Re-authoring the rule set in Studio gives the new rule a clean slate.
        let replacement = EventRule(
            name: "once again",
            trigger: .blockTouched(blockID: pad.id),
            actions: [.playSound(name: "x")],
            maxFireCount: 1,
            cooldown: 0
        )
        machine.apply(.rulesReplaced([replacement]))
        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: pad.id)).isEmpty)
    }

    func testDeltaInsertsAreVisibleToRules() {
        var machine = EventMachine(world: makeWorld())
        machine.addPlayer(snapshot(alice, name: "Alice"))
        started(&machine)

        let coin = BlockData(name: "Late Coin", behavior: .collectible, scoreValue: 7)
        machine.apply(.insert(coin))
        XCTAssertFalse(machine.handle(.touched(peer: alice, blockID: coin.id)).isEmpty)
        XCTAssertEqual(machine.player(alice)?.score, 7)
    }

    // MARK: Effect grouping

    func testEffectsSplitIntoBroadcastAndTargetedPayloads() {
        let effects: [EventMachine.Effect] = [
            .init(ruleID: nil, targetPeerID: nil, action: .announce(message: "everyone", duration: 1)),
            .init(ruleID: nil, targetPeerID: alice, action: .awardPoints(10)),
            .init(ruleID: nil, targetPeerID: alice, action: .playSound(name: "ding")),
            .init(ruleID: nil, targetPeerID: bob, action: .teleportPlayer(to: .zero))
        ]
        let (broadcast, targeted) = effects.groupedIntoPayloads()

        XCTAssertEqual(broadcast?.actions.count, 1)
        XCTAssertEqual(targeted[alice]?.actions.count, 2)
        XCTAssertEqual(targeted[bob]?.actions.count, 1)
        XCTAssertEqual(targeted[alice]?.targetPeerID, alice)
    }

    func testGroupingAnEmptyListProducesNothing() {
        let (broadcast, targeted) = [EventMachine.Effect]().groupedIntoPayloads()
        XCTAssertNil(broadcast)
        XCTAssertTrue(targeted.isEmpty)
    }

    // MARK: Movement

    func testJumpOnlyWorksWhenGrounded() {
        let grounded = PlayerSnapshot(peerID: alice, isGrounded: true)
        let airborne = PlayerSnapshot(peerID: alice, velocity: Vec3(0, -2, 0), isGrounded: false)
        let input = MovementInput(isJumping: true)

        let jumped = CharacterSolver.step(snapshot: grounded, input: input, deltaTime: 1.0 / 60)
        XCTAssertEqual(jumped.velocity.y, MovementConfig.default.jumpSpeed, accuracy: 1e-4)

        let denied = CharacterSolver.step(snapshot: airborne, input: input, deltaTime: 1.0 / 60)
        XCTAssertLessThan(denied.velocity.y, 0, "no double jumps")
    }

    func testGravityIsClampedToTerminalVelocity() {
        var snapshot = PlayerSnapshot(peerID: alice, isGrounded: false)
        for _ in 0..<600 {
            let result = CharacterSolver.step(snapshot: snapshot, input: .idle, deltaTime: 1.0 / 60)
            snapshot.velocity = result.velocity
        }
        XCTAssertEqual(snapshot.velocity.y, MovementConfig.default.maxFallSpeed, accuracy: 1e-3)
    }

    func testStickIsRotatedIntoCameraSpace() {
        let snapshot = PlayerSnapshot(peerID: alice, isGrounded: true)
        // Push the stick "up" with the camera looking along -Z: move along -Z.
        let forward = CharacterSolver.step(
            snapshot: snapshot,
            input: MovementInput(stick: Vec3(0, 0, 1), cameraYawDegrees: 0),
            deltaTime: 1.0 / 60
        )
        XCTAssertLessThan(forward.velocity.z, -1)
        XCTAssertEqual(forward.velocity.x, 0, accuracy: 1e-4)

        // Same stick, camera yawed 90°: movement follows the camera.
        let turned = CharacterSolver.step(
            snapshot: snapshot,
            input: MovementInput(stick: Vec3(0, 0, 1), cameraYawDegrees: 90),
            deltaTime: 1.0 / 60
        )
        XCTAssertLessThan(turned.velocity.x, -1)
        XCTAssertEqual(turned.velocity.z, 0, accuracy: 1e-3)
    }

    func testDiagonalInputIsNotFaster() {
        let snapshot = PlayerSnapshot(peerID: alice, isGrounded: true)
        let straight = CharacterSolver.step(snapshot: snapshot, input: MovementInput(stick: Vec3(0, 0, 1)), deltaTime: 1.0 / 60)
        let diagonal = CharacterSolver.step(snapshot: snapshot, input: MovementInput(stick: Vec3(1, 0, 1)), deltaTime: 1.0 / 60)

        let straightSpeed = Vec3(straight.velocity.x, 0, straight.velocity.z).length
        let diagonalSpeed = Vec3(diagonal.velocity.x, 0, diagonal.velocity.z).length
        XCTAssertEqual(diagonalSpeed, straightSpeed, accuracy: 1e-3)
    }

    func testReleasingTheStickDecaysToAStop() {
        var snapshot = PlayerSnapshot(peerID: alice, velocity: Vec3(5, 0, 0), isGrounded: true)
        for _ in 0..<120 {
            snapshot.velocity = CharacterSolver.step(snapshot: snapshot, input: .idle, deltaTime: 1.0 / 60).velocity
        }
        XCTAssertEqual(Vec3(snapshot.velocity.x, 0, snapshot.velocity.z).length, 0, accuracy: 0.05)
    }

    func testRunningIsFasterThanWalking() {
        let snapshot = PlayerSnapshot(peerID: alice, isGrounded: true)
        let walk = CharacterSolver.step(snapshot: snapshot, input: MovementInput(stick: Vec3(0, 0, 1)), deltaTime: 1.0 / 60)
        let run = CharacterSolver.step(snapshot: snapshot, input: MovementInput(stick: Vec3(0, 0, 1), isRunning: true), deltaTime: 1.0 / 60)
        XCTAssertGreaterThan(abs(run.velocity.z), abs(walk.velocity.z))
    }

    func testLargeTimeStepsAreClamped() {
        // A stall (app backgrounded) must not teleport the player into orbit.
        let snapshot = PlayerSnapshot(peerID: alice, isGrounded: false)
        let result = CharacterSolver.step(snapshot: snapshot, input: .idle, deltaTime: 30)
        XCTAssertGreaterThan(result.velocity.y, MovementConfig.default.gravity * 0.2)
    }

    func testFacingTurnsTowardMovementGradually() {
        var snapshot = PlayerSnapshot(peerID: alice, yawDegrees: 0, isGrounded: true)
        let input = MovementInput(stick: Vec3(1, 0, 0))
        let oneFrame = CharacterSolver.step(snapshot: snapshot, input: input, deltaTime: 1.0 / 60)
        XCTAssertLessThan(abs(oneFrame.yawDegrees), 90, "turning is rate-limited, not instant")

        for _ in 0..<60 {
            snapshot.yawDegrees = CharacterSolver.step(snapshot: snapshot, input: input, deltaTime: 1.0 / 60).yawDegrees
        }
        XCTAssertEqual(abs(normalizeDegrees(snapshot.yawDegrees - 90)), 0, accuracy: 1.0)
    }

    func testIdleInputKeepsFacing() {
        let snapshot = PlayerSnapshot(peerID: alice, yawDegrees: 137, isGrounded: true)
        let result = CharacterSolver.step(snapshot: snapshot, input: .idle, deltaTime: 1.0 / 60)
        XCTAssertEqual(result.yawDegrees, 137, accuracy: 1e-4)
    }

    func testInterpolationTakesShortestYawArc() {
        let from = PlayerSnapshot(peerID: alice, yawDegrees: 170)
        var to = PlayerSnapshot(peerID: alice, position: Vec3(10, 0, 0))
        to.yawDegrees = -170
        let mid = from.interpolated(toward: to, t: 0.5)
        XCTAssertEqual(abs(mid.yawDegrees), 180, accuracy: 1e-3, "must cross 180, not sweep back through 0")
        XCTAssertEqual(mid.position.x, 5, accuracy: 1e-4)
    }
}
