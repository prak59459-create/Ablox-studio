import XCTest
@testable import AbloxCore

/// The script game API, played headlessly: no iPad, no network, just inputs in
/// and effects out — which is exactly what the host does with it.
final class GameRuntimeTests: XCTestCase {

    private let alice = PeerID()
    private let bob = PeerID()

    // MARK: Helpers

    private func snapshot(_ peer: PeerID, _ name: String) -> PlayerSnapshot {
        var profile = AvatarProfile.default
        profile.displayName = name
        return PlayerSnapshot(peerID: peer, profile: profile)
    }

    private func game(_ script: String?, world: WorldDocument = WorldDocument(name: "Arena")) -> GameRuntime {
        var world = world
        world.script = script
        return GameRuntime(world: world, seed: 42)
    }

    /// Alice and Bob, both present before the round starts — as when a host
    /// has the lobby full and presses play.
    @discardableResult
    private func startWithBoth(_ game: GameRuntime) -> [GameRuntime.Effect] {
        game.addPlayer(snapshot(alice, "Alice"))
        game.addPlayer(snapshot(bob, "Bob"))
        return game.handle(.roundStarted)
    }

    private func place(_ game: GameRuntime, _ peer: PeerID, at position: Vec3) {
        game.updateTransform(PlayerTransformPayload(peerID: peer, position: position, yawDegrees: 0))
    }

    /// Alice at z = -10 shoots straight down +z, where Bob stands at the origin.
    @discardableResult
    private func aliceShootsBob(_ game: GameRuntime, at time: Double) -> [GameRuntime.Effect] {
        place(game, alice, at: Vec3(0, 0, -10))
        place(game, bob, at: .zero)
        return game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 0, 1)), from: alice, at: time)
    }

    private func reaching(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [EventAction] {
        effects.filter { $0.targetPeerID == nil || $0.targetPeerID == peer }.map(\.action)
    }

    private func scripted(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [ScriptEffect] {
        reaching(peer, effects).compactMap { if case let .script(effect) = $0 { return effect }; return nil }
    }

    private func healths(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [Double] {
        scripted(peer, effects).compactMap { if case let .health(current, _) = $0 { return current }; return nil }
    }

    private func announcements(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [String] {
        reaching(peer, effects).compactMap {
            switch $0 {
            case let .announce(message, _): return message
            case let .endRound(message): return message
            default: return nil
            }
        }
    }

    // MARK: A whole 1v1

    private let oneVersusOne = #"""
    let goal = 3

    on start()
      game.respawn_time = 2
      hud_text("title", "1v1", {at: "top"})
    end

    on join(p)
      p.camera = "first"
      p.give("rifle")
      p.kills = 0
      p.hud_text("kills", "Kills: 0", {at: "top_left"})
    end

    on death(victim, killer)
      if killer then
        killer.kills = killer.kills + 1
        killer.score = killer.kills
        killer.hud_text("kills", "Kills: " + killer.kills, {at: "top_left"})
        if killer.kills >= goal then
          end_round(killer.name + " wins!")
        end
      end
    end
    """#

    func testAOneVersusOneMatchPlaysToTheEnd() {
        let game = game(oneVersusOne)
        let opening = startWithBoth(game)
        XCTAssertNil(game.compileError)
        XCTAssertTrue(game.drainErrors().isEmpty)

        // Both are set up for a shooter, each on their own screen.
        for peer in [alice, bob] {
            let mine = scripted(peer, opening)
            XCTAssertTrue(mine.contains(.camera(.firstPerson)))
            XCTAssertTrue(mine.contains(.equip(WeaponSpec.presets["rifle"])))
            XCTAssertTrue(mine.contains(.hud(HUDElement(id: "title", kind: .text("1v1"), anchor: .top))))
        }
        XCTAssertEqual(opening.filter { $0.action == .script(.camera(.firstPerson)) }.count, 2,
                       "one camera change per player, not a broadcast each")

        // Kill one: three rifle hits (34 each).
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1.0)), [66])
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1.6)), [32])
        let killingShot = aliceShootsBob(game, at: 2.2)
        XCTAssertEqual(healths(bob, killingShot).last, 0)
        XCTAssertTrue(scripted(alice, killingShot).contains(.hitMarker(killed: true)))
        XCTAssertTrue(scripted(bob, killingShot).contains(.movement(speed: 0, jump: 0)), "the knocked-out can't walk")
        XCTAssertTrue(reaching(alice, killingShot).contains(.awardPoints(1)))
        XCTAssertEqual(game.players[alice]?.score, 1)

        // Shooting the knocked-out does nothing.
        let overkill = aliceShootsBob(game, at: 2.8)
        XCTAssertTrue(healths(bob, overkill).isEmpty)
        XCTAssertFalse(scripted(alice, overkill).contains { if case .hitMarker = $0 { return true }; return false })

        // Bob comes back two seconds after the knockout.
        XCTAssertTrue(healths(bob, game.advance(to: 4.0)).isEmpty)
        let comeback = game.advance(to: 4.3)
        XCTAssertEqual(healths(bob, comeback), [100])
        XCTAssertTrue(reaching(bob, comeback).contains { if case .teleportPlayer = $0 { return true }; return false })

        // Kill two. The overkill shot spent a round, so the sixth goes at 5.0
        // and starts a two-second reload; a shot during it is refused.
        aliceShootsBob(game, at: 4.4)
        let lastRound = aliceShootsBob(game, at: 5.0)
        XCTAssertEqual(healths(bob, lastRound), [32])
        XCTAssertTrue(scripted(alice, lastRound).contains(.ammo(current: 0, magazine: 6, reloading: true)))
        XCTAssertTrue(healths(bob, aliceShootsBob(game, at: 5.6)).isEmpty, "no shooting while reloading")
        XCTAssertTrue(scripted(alice, game.advance(to: 7.1)).contains(.ammo(current: 6, magazine: 6, reloading: false)))
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 7.2)).last, 0)
        XCTAssertEqual(game.players[alice]?.score, 2)

        // Kill three wins it.
        game.advance(to: 9.3)
        aliceShootsBob(game, at: 9.4)
        aliceShootsBob(game, at: 10.0)
        let winner = aliceShootsBob(game, at: 10.6)
        XCTAssertTrue(announcements(bob, winner).contains("Alice wins!"))
        XCTAssertTrue(scripted(alice, winner).contains(.hud(HUDElement(id: "kills", kind: .text("Kills: 3"), anchor: .topLeft))))
        XCTAssertTrue(game.isRoundOver)
        XCTAssertEqual(game.players[alice]?.score, 3)

        // Nothing moves once it is over.
        XCTAssertTrue(aliceShootsBob(game, at: 14).isEmpty)
        XCTAssertTrue(game.drainErrors().isEmpty)
    }

    func testARestartPutsEveryoneBackToTheStart() {
        let game = game(oneVersusOne)
        startWithBoth(game)
        aliceShootsBob(game, at: 1)

        let restart = game.handle(.roundStarted)
        XCTAssertTrue(scripted(bob, restart).contains(.clearHUD))
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 5)), [66], "health starts from full again")
    }

    // MARK: Combat rules

    func testTeammatesCannotHurtEachOther() {
        let game = game(#"""
        on join(p)
          p.team = "red"
          p.give("blaster")
        end
        """#)
        startWithBoth(game)
        XCTAssertTrue(healths(bob, aliceShootsBob(game, at: 1)).isEmpty)
    }

    func testFriendlyFireCanBeTurnedOn() {
        let game = game(#"""
        on start()
          game.friendly_fire = true
        end
        on join(p)
          p.team = "red"
          p.give("blaster")
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1)), [80])
    }

    func testOnHitCanChangeTheDamage() {
        let game = game(#"""
        on join(p)
          p.give("blaster")
        end
        on hit(victim, attacker, amount)
          if victim.name == "Bob" then
            return amount * 2
          end
          return 0
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1)), [60], "blaster 20, doubled")

        place(game, bob, at: Vec3(0, 0, -10))
        place(game, alice, at: .zero)
        let backwards = game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 0, 1)), from: bob, at: 2)
        XCTAssertTrue(healths(alice, backwards).isEmpty, "returning 0 cancels the hit")
    }

    func testWithoutAWeaponNothingFires() {
        let game = game("on start()\nend")
        startWithBoth(game)
        XCTAssertTrue(aliceShootsBob(game, at: 1).isEmpty)
    }

    func testCustomWeapons() {
        let game = game(#"""
        on start()
          weapon("sniper", {model: "rifle", damage: 90, ammo: 1})
        end
        on join(p)
          p.give("Sniper")
        end
        """#)
        let opening = startWithBoth(game)
        let equipped = scripted(alice, opening).compactMap { effect -> WeaponSpec? in
            if case let .equip(weapon) = effect { return weapon }
            return nil
        }.first
        XCTAssertEqual(equipped?.name, "sniper")
        XCTAssertEqual(equipped?.damage, 90)
        XCTAssertEqual(equipped?.magazine, 1)
        XCTAssertEqual(equipped?.range, WeaponSpec.presets["rifle"]?.range, "everything not given comes from the model")
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1)), [10])
    }

    func testAnUnknownWeaponIsAHelpfulError() {
        let game = game("on join(p)\n  p.give(\"banana\")\nend")
        startWithBoth(game)
        let errors = game.drainErrors()
        XCTAssertEqual(errors.count, 1, "the same mistake for two players is reported once")
        XCTAssertEqual(errors.first?.line, 2)
        XCTAssertTrue(errors.first?.message.contains("rifle") ?? false, "it lists the weapons there are")
    }

    func testKnockedOutPlayersStayDownWhenTheScriptSaysSo() {
        let game = game(#"""
        on start()
          game.respawn_time = -1
        end
        on join(p)
          p.give("pistol")
          p.max_health = 10
          p.hud_button("revive", "Revive")
        end
        on button(p, id)
          for each in players() do
            if not each.alive then each.respawn() end
          end
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1)).last, 0, "15 damage against 10 health")
        XCTAssertTrue(healths(bob, game.advance(to: 60)).isEmpty, "no automatic respawn")

        let revived = game.handle(.button(id: "revive"), from: alice, at: 61)
        XCTAssertEqual(healths(bob, revived), [10])
    }

    func testTheKnockedOutCannotShoot() {
        let game = game("on join(p)\n  p.give(\"pistol\")\n  p.max_health = 10\nend")
        startWithBoth(game)
        aliceShootsBob(game, at: 1)

        place(game, bob, at: Vec3(0, 0, -10))
        place(game, alice, at: .zero)
        let fromTheFloor = game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 0, 1)), from: bob, at: 1.5)
        XCTAssertTrue(fromTheFloor.isEmpty)
    }

    func testMovementIsClamped() {
        let game = game("on join(p)\n  p.speed = 50\n  p.jump = -2\nend")
        let opening = startWithBoth(game)
        XCTAssertTrue(scripted(alice, opening).contains(.movement(speed: 3, jump: 1)))
        XCTAssertTrue(scripted(alice, opening).contains(.movement(speed: 3, jump: 0)))
    }

    // MARK: Screen GUI

    func testALateJoinerSeesWhatEveryoneElseSees() {
        let game = game(#"""
        on start()
          hud_text("title", "Capture the flag", {at: "top", color: "red", size: "large"})
          hud_bar("time", 30, 60)
        end
        on join(p)
          p.hud_text("hello", "Hi " + p.name)
        end
        """#)
        game.addPlayer(snapshot(alice, "Alice"))
        game.handle(.roundStarted)

        let arrival = game.addPlayer(snapshot(bob, "Bob"))
        let bobSees = scripted(bob, arrival)
        XCTAssertTrue(bobSees.contains(.hud(HUDElement(id: "title", kind: .text("Capture the flag"), anchor: .top,
                                                       color: ScriptColor.parse("red"), size: .large))))
        XCTAssertTrue(bobSees.contains(.hud(HUDElement(id: "time", kind: .bar(value: 30, maximum: 60)))))
        XCTAssertTrue(bobSees.contains(.hud(HUDElement(id: "hello", kind: .text("Hi Bob")))))
        XCTAssertTrue(arrival.allSatisfy { $0.targetPeerID == bob }, "Alice already has them")
    }

    func testOnlyButtonsOnScreenCanBePressed() {
        let game = game(#"""
        on join(p)
          if p.name == "Alice" then p.hud_button("shop", "Shop") end
        end
        on button(p, id)
          p.score = p.score + 1
        end
        """#)
        startWithBoth(game)
        XCTAssertTrue(reaching(alice, game.handle(.button(id: "shop"), from: alice, at: 1)).contains(.awardPoints(1)))
        XCTAssertTrue(game.handle(.button(id: "shop"), from: bob, at: 1).isEmpty, "Bob has no shop button")
        XCTAssertTrue(game.handle(.button(id: "secret"), from: alice, at: 1).isEmpty)
    }

    func testTheScreenHasALimit() {
        let game = game(#"""
        on join(p)
          for i in 1 to 30 do
            p.hud_text("item" + i, "x")
          end
        end
        """#)
        startWithBoth(game)
        let errors = game.drainErrors()
        XCTAssertEqual(errors.first?.kind, .limit)
    }

    func testBadAnchorsAreExplained() {
        let game = game("on start()\n  hud_text(\"a\", \"b\", {at: \"middle\"})\nend")
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().first?.message.contains("top_left") ?? false)
    }

    // MARK: World and rules

    func testScriptsChangeBlocksForEveryone() {
        var world = WorldDocument(name: "Arena")
        let door = BlockData(name: "Door")
        world.insert(door)
        let game = game("on start()\n  block(\"door\").visible = false\n  block(\"Door\").color = \"blue\"\nend", world: world)
        let opening = startWithBoth(game)
        XCTAssertEqual(game.world.block(id: door.id)?.isVisible, false, "late joiners get the changed world")
        XCTAssertEqual(game.world.block(id: door.id)?.color, ScriptColor.parse("blue"))
        XCTAssertTrue(opening.contains(where: { $0.targetPeerID == nil && $0.action == .setVisible(blockID: door.id, visible: false) }))
    }

    func testScoresFromScriptsTripScoreRules() {
        var world = WorldDocument(name: "Arena")
        world.rules = [EventRule(name: "Win", trigger: .scoreReached(score: 3), actions: [.endRound(message: "Winner")])]
        let game = game("on join(p)\n  if p.name == \"Bob\" then p.score = 3 end\nend", world: world)
        let opening = startWithBoth(game)
        XCTAssertTrue(announcements(alice, opening).contains("Winner"))
    }

    func testRulesStillRunWhenTheScriptDoesNotParse() {
        var world = WorldDocument(name: "Arena")
        world.rules = [EventRule(name: "Hello", trigger: .worldStart, actions: [.announce(message: "Welcome", duration: 2)])]
        let game = game("on start(\n", world: world)
        let opening = startWithBoth(game)
        XCTAssertNotNil(game.compileError)
        XCTAssertEqual(game.drainErrors().count, 1)
        XCTAssertTrue(announcements(alice, opening).contains("Welcome"))
        XCTAssertFalse(game.isScriptRunning)
    }

    func testTouchesAreThrottled() {
        var world = WorldDocument(name: "Arena")
        let lava = BlockData(name: "Lava")
        world.insert(lava)
        let game = game("on touch(p, b)\n  if b.name == \"Lava\" then p.damage(10) end\nend", world: world)
        startWithBoth(game)
        var hits = 0
        for step in 0..<10 {
            game.advance(to: Double(step) * 0.1)
            hits += healths(alice, game.handle(.touched(peer: alice, blockID: lava.id))).count
        }
        XCTAssertEqual(hits, 2, "a second of standing on it is two touches, not sixty")
    }

    func testLeaveCanStillReadTheName() {
        let game = game("on leave(p)\n  announce(p.name + \" left\")\nend")
        startWithBoth(game)
        XCTAssertEqual(announcements(alice, game.removePlayer(bob)), ["Bob left"])
    }

    // MARK: Time

    func testTimers() {
        let game = game(#"""
        let ticks = 0
        on start()
          after(1, func() announce("one") end)
          let id = every(0.5, func()
            ticks = ticks + 1
            if ticks == 3 then announce("three") end
          end)
          after(10, func() cancel(id) end)
        end
        """#)
        startWithBoth(game)
        var heard: [String] = []
        for step in 1...30 {
            heard += announcements(alice, game.advance(to: Double(step) * 0.1))
        }
        XCTAssertEqual(heard, ["one", "three"])
    }

    func testTickGetsTheTimeSinceTheLastTick() {
        let game = game("on tick(dt)\n  print(dt)\nend")
        startWithBoth(game)
        game.advance(to: 0.1)
        game.advance(to: 0.3)
        XCTAssertEqual(game.drainOutput(), ["0.1", "0.2"])
    }

    // MARK: Safety

    func testAnErrorInTickIsReportedOnceAndTheGameGoesOn() {
        let game = game(#"""
        on join(p)
          p.give("pistol")
        end
        on tick(dt)
          let broken = nil
          print(broken.health)
        end
        """#)
        startWithBoth(game)
        for step in 1...20 { game.advance(to: Double(step) * 0.1) }
        let errors = game.drainErrors()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.line, 6)
        XCTAssertFalse(healths(bob, aliceShootsBob(game, at: 3)).isEmpty, "shooting still works")
    }

    func testAnEndlessLoopCannotFreezeTheHost() {
        let game = game("on tick(dt)\n  while true do\n  end\nend")
        startWithBoth(game)
        game.advance(to: 0.1)
        XCTAssertEqual(game.drainErrors().first?.kind, .limit)
    }

    func testTimersCannotPileUpForever() {
        let game = game("on tick(dt)\n  every(1, func() end)\nend")
        startWithBoth(game)
        for step in 1...300 { game.advance(to: Double(step) * 0.1) }
        XCTAssertEqual(game.drainErrors().first?.kind, .limit)
    }

    // MARK: Studio's Check button

    func testCheckFindsMisspelledEvents() {
        let problems = GameRuntime.check("on joni(p)\nend\n\non start()\nend\n")
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.line, 1)
        XCTAssertTrue(problems.first?.message.contains("join") ?? false)
    }

    func testCheckAcceptsEveryRealEvent() {
        let source = GameRuntime.Event.allCases.map { "on \($0.rawValue)()\nend" }.joined(separator: "\n")
        XCTAssertEqual(GameRuntime.check(source), [])
    }

    func testCheckReportsSyntaxErrors() {
        let problems = GameRuntime.check("let x = \n")
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems.first?.kind, .syntax)
    }

    // MARK: Wire format

    func testScriptEffectsSurviveTheWire() throws {
        let effects: [ScriptEffect] = [
            .hud(HUDElement(id: "a", kind: .text("Hi"), anchor: .bottomRight, color: .white, size: .small)),
            .hud(HUDElement(id: "b", kind: .bar(value: 3, maximum: 10))),
            .hud(HUDElement(id: "c", kind: .button("Go"))),
            .removeHUD(id: "a"),
            .clearHUD,
            .camera(.firstPerson),
            .equip(WeaponSpec.presets["pistol"]),
            .equip(nil),
            .ammo(current: 3, magazine: 10, reloading: true),
            .health(current: 50, maximum: 100),
            .movement(speed: 1.5, jump: 0.5),
            .hitMarker(killed: true),
            .damageFlash,
            .tracer(from: Vec3(1, 2, 3), to: Vec3(4, 5, 6))
        ]
        for effect in effects {
            let action = EventAction.script(effect)
            XCTAssertEqual(try JSONDecoder().decode(EventAction.self, from: JSONEncoder().encode(action)), action)
        }
    }

    func testPlayerInputSurvivesTheWire() throws {
        let inputs: [PlayerInputPayload.Input] = [
            .fire(origin: Vec3(0, 1.6, 0), direction: Vec3(0, 0, -1)),
            .button(id: "shop"),
            .reload
        ]
        for input in inputs {
            let payload = PlayerInputPayload(peerID: alice, input: input)
            XCTAssertEqual(try JSONDecoder().decode(PlayerInputPayload.self, from: JSONEncoder().encode(payload)), payload)
        }
    }

    func testWorldsSavedBeforeScriptsStillOpen() throws {
        let old = WorldDocument(name: "Old")
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"script\""))
        XCTAssertNil(try JSONDecoder().decode(WorldDocument.self, from: data).script)

        var scripted = old
        scripted.script = "on start()\nend"
        XCTAssertEqual(try JSONDecoder().decode(WorldDocument.self, from: JSONEncoder().encode(scripted)).script, scripted.script)
    }

    func testTheScriptTravelsAsADelta() throws {
        var world = WorldDocument(name: "Co-edit")
        let delta = WorldDelta.scriptReplaced("on start()\nend")
        let restored = try JSONDecoder().decode(WorldDelta.self, from: JSONEncoder().encode(delta))
        XCTAssertEqual(restored, delta)
        XCTAssertTrue(restored.apply(to: &world))
        XCTAssertEqual(world.script, "on start()\nend")
        XCTAssertTrue(WorldDelta.scriptReplaced(nil).apply(to: &world))
        XCTAssertNil(world.script)
    }

    func testNamedColours() {
        XCTAssertEqual(ScriptColor.parse("red"), ScriptColor.parse("赤"))
        XCTAssertEqual(ScriptColor.parse(" Blue "), ScriptColor.parse("#3B82F6"))
        XCTAssertNil(ScriptColor.parse("bleu"))
        XCTAssertNil(ScriptColor.parse("123456"), "hex needs its #, so a typo is not silently a colour")
    }
}

/// Every sample Studio offers has to work the moment it is inserted.
final class ScriptSampleTests: XCTestCase {

    func testEverySampleRunsCleanly() {
        var world = WorldDocument(name: "Sample")
        var coin = BlockData(name: "Coin")
        coin.tags = ["coin"]
        world.insert(coin)
        for sample in ScriptSamples.all {
            world.script = sample.source
            let report = GameRuntime.testRun(world: world, seconds: 3)
            XCTAssertEqual(report.problems, [], "\(sample.id): \(report.problems.map(\.description))")
            XCTAssertFalse(sample.title.isEmpty)
            XCTAssertFalse(sample.summary.isEmpty)
        }
    }

    func testSampleIDsAreUnique() {
        let ids = ScriptSamples.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTheDuelSampleSetsUpAShooter() {
        var world = WorldDocument(name: "Duel")
        world.script = ScriptSamples.duel.source
        let notes = GameRuntime.testRun(world: world).notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("rifle"), notes)
        XCTAssertTrue(notes.contains("Knockouts: 0"), notes)
    }

    func testTheTimerSampleEndsTheRound() {
        var world = WorldDocument(name: "Timer")
        world.script = ScriptSamples.timerAndButtons.source
        let report = GameRuntime.testRun(world: world, seconds: 61)
        XCTAssertTrue(report.notes.contains { $0.contains("Time's up!") }, report.notes.joined(separator: "\n"))
    }

    func testATestRunReportsSyntaxErrorsAndStops() {
        var world = WorldDocument(name: "Broken")
        world.script = "on start(\n"
        let report = GameRuntime.testRun(world: world)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertTrue(report.notes.isEmpty)
    }

    func testATestRunReportsPrintedLines() {
        var world = WorldDocument(name: "Hello")
        world.script = "on join(p)\n  print(\"hello \" + p.name)\nend"
        XCTAssertEqual(GameRuntime.testRun(world: world).output.count, 2, "one per player")
    }
}

/// Folding host effects into what one player's screen shows.
final class ScriptedPlayerStateTests: XCTestCase {

    func testScreenItemsKeepTheirPlaceWhenUpdated() {
        var state = ScriptedPlayerState()
        state.apply(.hud(HUDElement(id: "a", kind: .text("1"))))
        state.apply(.hud(HUDElement(id: "b", kind: .text("2"))))
        state.apply(.hud(HUDElement(id: "a", kind: .text("3"))))
        XCTAssertEqual(state.hud.map(\.id), ["a", "b"])
        XCTAssertEqual(state.element("a")?.kind, .text("3"))
        state.apply(.removeHUD(id: "a"))
        XCTAssertEqual(state.hud.map(\.id), ["b"])
        state.apply(.clearHUD)
        XCTAssertTrue(state.hud.isEmpty)
    }

    func testFiringNeedsAWeaponAmmoAndHealth() {
        var state = ScriptedPlayerState()
        XCTAssertFalse(state.canFire)
        state.apply(.equip(WeaponSpec.presets["pistol"]))
        XCTAssertTrue(state.canFire)
        state.apply(.ammo(current: 0, magazine: 10, reloading: true))
        XCTAssertFalse(state.canFire)
        state.apply(.ammo(current: 10, magazine: 10, reloading: false))
        state.apply(.health(current: 0, maximum: 100))
        XCTAssertTrue(state.isKnockedOut)
        XCTAssertFalse(state.canFire)
        state.apply(.equip(nil))
        XCTAssertNil(state.ammo, "no weapon, no ammo counter")
    }

    func testEachHitIsCounted() {
        var state = ScriptedPlayerState()
        state.apply(.hitMarker(killed: false))
        state.apply(.hitMarker(killed: true))
        state.apply(.damageFlash)
        XCTAssertEqual(state.hitMarkerCount, 2)
        XCTAssertTrue(state.lastHitWasKnockout)
        XCTAssertEqual(state.damageFlashCount, 1)
    }
}

/// Studio's reference has to list everything a script can use.
final class ScriptReferenceTests: XCTestCase {

    private var allCode: String {
        ScriptReference.sections.flatMap(\.entries).map(\.code).joined(separator: "\n")
    }

    func testEveryEventIsListed() {
        for event in GameRuntime.Event.allCases {
            XCTAssertTrue(allCode.contains("on \(event.rawValue)("), "on \(event.rawValue) is missing")
        }
    }

    func testEveryFunctionIsListed() {
        let names = GameRuntime.gameAPINames + ScriptInterpreter.standardLibraryNames
        for name in names {
            XCTAssertNotNil(allCode.range(of: "\\b\(name)\\b", options: .regularExpression), "\(name) is missing")
        }
    }

    func testEveryPlayerAndBlockMemberIsListed() {
        for name in GameRuntime.playerMemberNames {
            XCTAssertTrue(allCode.contains("p.\(name)"), "p.\(name) is missing")
        }
        for name in GameRuntime.blockMemberNames where name != "id" {
            XCTAssertTrue(allCode.contains("b.\(name)"), "b.\(name) is missing")
        }
    }

    func testEveryExampleInTheReferenceParses() throws {
        // The ones that are a whole statement on their own.
        for code in ["let score = 0", "func add(a, b) return a + b end", "-- a note"] {
            XCTAssertNoThrow(try ScriptParser.parse(code), code)
        }
    }
}
