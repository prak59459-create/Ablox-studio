import XCTest
@testable import AbloxCore

/// The script game API, played headlessly: no iPad, no network, just inputs in
/// and effects out — which is exactly what the host does with it.
class RuntimeTestCase: XCTestCase {

    let alice = PeerID()
    let bob = PeerID()

    func snapshot(_ peer: PeerID, _ name: String) -> PlayerSnapshot {
        var profile = AvatarProfile.default
        profile.displayName = name
        return PlayerSnapshot(peerID: peer, profile: profile)
    }

    func game(_ script: String?, world: WorldDocument = WorldDocument(name: "Arena"),
              limits: ScriptInterpreter.Limits = ScriptInterpreter.Limits()) -> GameRuntime {
        var world = world
        world.scripts = script.map { [ScriptFile(name: "main", source: $0)] } ?? []
        return GameRuntime(world: world, seed: 42, limits: limits)
    }

    /// Alice and Bob, both present before the round starts — as when a host
    /// has the lobby full and presses play.
    @discardableResult
    func startWithBoth(_ game: GameRuntime) -> [GameRuntime.Effect] {
        game.addPlayer(snapshot(alice, "Alice"))
        game.addPlayer(snapshot(bob, "Bob"))
        return game.handle(.roundStarted)
    }

    func place(_ game: GameRuntime, _ peer: PeerID, at position: Vec3) {
        game.updateTransform(PlayerTransformPayload(peerID: peer, position: position, yawDegrees: 0))
    }

    /// Alice at z = -10 shoots straight down +z, where Bob stands at the origin.
    @discardableResult
    func aliceShootsBob(_ game: GameRuntime, at time: Double) -> [GameRuntime.Effect] {
        place(game, alice, at: Vec3(0, 0, -10))
        place(game, bob, at: .zero)
        return game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 0, 1)), from: alice, at: time)
    }

    func reaching(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [EventAction] {
        effects.filter { $0.targetPeerID == nil || $0.targetPeerID == peer }.map(\.action)
    }

    func scripted(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [ScriptEffect] {
        reaching(peer, effects).compactMap { if case let .script(effect) = $0 { return effect }; return nil }
    }

    func screen(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> ScriptedPlayerState {
        var state = ScriptedPlayerState()
        scripted(peer, effects).forEach { state.apply($0) }
        return state
    }

    func healths(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [Double] {
        scripted(peer, effects).compactMap { if case let .health(current, _) = $0 { return current }; return nil }
    }

    func announcements(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [String] {
        reaching(peer, effects).compactMap {
            switch $0 {
            case let .announce(message, _): return message
            case let .endRound(message): return message
            case let .script(.chat(line)): return line
            default: return nil
            }
        }
    }
}

final class GameRuntimeTests: RuntimeTestCase {

    // MARK: A whole 1v1

    private let oneVersusOne = #"""
    let goal = 3

    on start()
      game.respawn_time = 2
      ui_text("title", "1v1", {at: "top"})
    end

    on join(p)
      p.camera = "first"
      p.give("rifle")
      p.kills = 0
      p.ui_text("kills", "Kills: 0", {at: "top_left"})
    end

    on death(victim, killer)
      if killer then
        killer.kills = killer.kills + 1
        killer.score = killer.kills
        killer.ui_text("kills", "Kills: " + killer.kills)
        if killer.kills >= goal then
          end_round(killer.name + " wins!")
        end
      end
    end
    """#

    func testAOneVersusOneMatchPlaysToTheEnd() {
        let game = game(oneVersusOne)
        let opening = startWithBoth(game)
        XCTAssertTrue(game.compileErrors.isEmpty)
        XCTAssertTrue(game.drainErrors().isEmpty)

        for peer in [alice, bob] {
            let mine = screen(peer, opening)
            XCTAssertEqual(mine.camera.mode, .firstPerson)
            XCTAssertEqual(mine.weapon, WeaponSpec.presets["rifle"])
            XCTAssertEqual(mine.element("title")?.text, "1v1")
        }
        XCTAssertEqual(opening.filter {
            if case .script(.camera) = $0.action { return true }; return false
        }.count, 2, "one camera change per player, not a broadcast each")

        // Kill one: three rifle hits (34 each).
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1.0)), [66])
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1.6)), [32])
        let killingShot = aliceShootsBob(game, at: 2.2)
        XCTAssertEqual(healths(bob, killingShot).last, 0)
        XCTAssertTrue(scripted(alice, killingShot).contains(.hitMarker(killed: true)))
        XCTAssertEqual(screen(bob, killingShot).movement.frozen, true, "the knocked-out can't walk")
        XCTAssertTrue(reaching(alice, killingShot).contains(.awardPoints(1)))
        XCTAssertEqual(game.players[alice]?.score, 1)

        // Shooting the knocked-out does nothing.
        let overkill = aliceShootsBob(game, at: 2.8)
        XCTAssertTrue(healths(bob, overkill).isEmpty)

        // Bob comes back two seconds after the knockout.
        XCTAssertTrue(healths(bob, game.advance(to: 4.0)).isEmpty)
        let comeback = game.advance(to: 4.3)
        XCTAssertEqual(healths(bob, comeback), [100])
        XCTAssertTrue(reaching(bob, comeback).contains { if case .teleportPlayer = $0 { return true }; return false })

        // Kill two. The overkill spent a round, so the sixth goes at 5.0 and
        // starts a two-second reload; a shot during it is refused.
        aliceShootsBob(game, at: 4.4)
        let lastRound = aliceShootsBob(game, at: 5.0)
        XCTAssertEqual(healths(bob, lastRound), [32])
        XCTAssertTrue(scripted(alice, lastRound).contains(.ammo(current: 0, magazine: 6, reloading: true)))
        XCTAssertTrue(healths(bob, aliceShootsBob(game, at: 5.6)).isEmpty, "no shooting while reloading")
        XCTAssertTrue(scripted(alice, game.advance(to: 7.1)).contains(.ammo(current: 6, magazine: 6, reloading: false)))
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 7.2)).last, 0)

        // Kill three wins it.
        game.advance(to: 9.3)
        aliceShootsBob(game, at: 9.4)
        aliceShootsBob(game, at: 10.0)
        let winner = aliceShootsBob(game, at: 10.6)
        XCTAssertTrue(announcements(bob, winner).contains("Alice wins!"))
        XCTAssertEqual(screen(alice, winner).element("kills")?.text, "Kills: 3")
        XCTAssertTrue(game.isRoundOver)
        XCTAssertEqual(game.players[alice]?.score, 3)

        XCTAssertTrue(aliceShootsBob(game, at: 14).isEmpty, "nothing moves once it is over")
        XCTAssertTrue(game.drainErrors().isEmpty)
    }

    func testUpdatingAScreenItemKeepsWhereItWas() {
        let game = game(oneVersusOne)
        let opening = startWithBoth(game)
        let before = screen(alice, opening).element("kills")
        XCTAssertEqual(before?.x, 0)
        aliceShootsBob(game, at: 1)
        aliceShootsBob(game, at: 1.6)
        let after = screen(alice, aliceShootsBob(game, at: 2.2)).element("kills")
        XCTAssertEqual(after?.text, "Kills: 1")
        XCTAssertEqual(after?.x, before?.x, "ui_text with only new words keeps the position")
        XCTAssertEqual(after?.offsetX, before?.offsetX)
    }

    func testARestartPutsEveryoneBackToTheStart() {
        let game = game(oneVersusOne)
        startWithBoth(game)
        aliceShootsBob(game, at: 1)

        let restart = game.handle(.roundStarted)
        XCTAssertTrue(scripted(bob, restart).contains(.clearUI))
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 5)), [66], "health starts from full again")
    }

    func testRestartRoundFromAScript() {
        let game = game("let rounds = 0\non start()\n  rounds = rounds + 1\n  print(rounds)\nend\non chat(p, text)\n  if text == \"again\" then restart_round() end\nend")
        startWithBoth(game)
        game.handleChat(from: alice, text: "again")
        game.advance(to: 0.1)
        XCTAssertEqual(game.drainOutput(), ["1", "1"], "a restart runs the script from the top, fresh")
    }

    // MARK: Combat rules

    func testTeammatesCannotHurtEachOther() {
        let game = game("on join(p)\n  p.team = \"red\"\n  p.give(\"blaster\")\nend")
        startWithBoth(game)
        XCTAssertTrue(healths(bob, aliceShootsBob(game, at: 1)).isEmpty)
    }

    func testFriendlyFireCanBeTurnedOn() {
        let game = game("on start()\n  game.friendly_fire = true\nend\non join(p)\n  p.team = \"red\"\n  p.give(\"blaster\")\nend")
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

    func testCustomWeaponsGoFarBeyondThePresets() {
        let game = game(#"""
        on start()
          weapon("railgun", {model: "rifle", damage: 5000, range: 900, ammo: 1})
        end
        on join(p)
          p.give("Railgun")
          p.max_health = 10000
          p.health = 10000
        end
        """#)
        let opening = startWithBoth(game)
        let equipped = screen(alice, opening).weapon
        XCTAssertEqual(equipped?.damage, 5000)
        XCTAssertEqual(equipped?.range, 900)
        XCTAssertEqual(equipped?.magazine, 1)
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1)).first, 5000)
    }

    func testAnUnknownWeaponIsAHelpfulError() {
        let game = game("on join(p)\n  p.give(\"banana\")\nend")
        startWithBoth(game)
        let errors = game.drainErrors()
        XCTAssertEqual(errors.count, 1, "the same mistake for two players is reported once")
        XCTAssertEqual(errors.first?.line, 2)
        XCTAssertEqual(errors.first?.file, "main.absc")
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
          p.ui_button("revive", "Revive")
        end
        on button(p, id)
          for each in players() do
            if not each.alive then each.respawn() end
          end
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(healths(bob, aliceShootsBob(game, at: 1)).last, 0)
        XCTAssertTrue(healths(bob, game.advance(to: 60)).isEmpty, "no automatic respawn")
        XCTAssertEqual(healths(bob, game.handle(.button(id: "revive"), from: alice, at: 61)), [10])
    }

    func testTheKnockedOutCannotShoot() {
        let game = game("on join(p)\n  p.give(\"pistol\")\n  p.max_health = 10\nend")
        startWithBoth(game)
        aliceShootsBob(game, at: 1)
        place(game, bob, at: Vec3(0, 0, -10))
        place(game, alice, at: .zero)
        XCTAssertTrue(game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 0, 1)), from: bob, at: 1.5).isEmpty)
    }

    // MARK: Moving and looking

    func testMovementCanGoFarButNotForever() {
        let game = game("on join(p)\n  p.speed = 50\n  p.jump = -2\n  p.gravity = 0.2\nend")
        let movement = screen(alice, startWithBoth(game)).movement
        XCTAssertEqual(movement.speed, 10)
        XCTAssertEqual(movement.jump, 0)
        XCTAssertEqual(movement.gravity, 0.2, accuracy: 0.0001)
    }

    func testCameraModesAndScreenControl() {
        let game = game(#"""
        on join(p)
          p.camera = "top"
          p.camera_distance = 30
          p.fov = 90
          p.controls = false
          p.default_ui = false
          p.fade("black", 2)
          p.shake(1, 0.5)
        end
        """#)
        let mine = screen(alice, startWithBoth(game))
        XCTAssertEqual(mine.camera.mode, .topDown)
        XCTAssertEqual(mine.camera.distance, 30)
        XCTAssertEqual(mine.camera.fieldOfView, 90)
        XCTAssertFalse(mine.showsControls)
        XCTAssertFalse(mine.showsDefaultUI)
        XCTAssertEqual(mine.fade.color, ScriptColor.parse("black"))
        XCTAssertEqual(mine.fade.seconds, 2)
        XCTAssertEqual(mine.shake.strength, 1)
    }

    func testAFixedCameraLooksAtSomething() {
        var world = WorldDocument(name: "Arena")
        world.insert(BlockData(name: "Stage", transform: Transform3D(position: Vec3(0, 0, 10))))
        let game = game("on join(p)\n  p.camera_look({x: 0, y: 10, z: 0}, block(\"Stage\"))\nend", world: world)
        let camera = screen(alice, startWithBoth(game)).camera
        XCTAssertEqual(camera.mode, .fixed)
        XCTAssertEqual(camera.position, Vec3(0, 10, 0))
        XCTAssertEqual(camera.target, Vec3(0, 0, 10))
    }

    func testTeleportLaunchAndFacing() {
        let game = game(#"""
        on join(p)
          if p.name == "Alice" then
            p.position = {x: 5, y: 10, z: 5}
            p.launch(0, 20, 0)
            p.yaw = 90
          end
        end
        """#)
        let opening = startWithBoth(game)
        XCTAssertTrue(reaching(alice, opening).contains(.teleportPlayer(to: Vec3(5, 10, 5))))
        XCTAssertTrue(scripted(alice, opening).contains(.launch(Vec3(0, 20, 0))))
        XCTAssertTrue(scripted(alice, opening).contains(.face(yawDegrees: 90)))
        XCTAssertEqual(game.players[alice]?.position, Vec3(5, 10, 5), "the host moves them at once, for shots")
    }

    func testAppearanceChangesReachEveryone() {
        let game = game(#"""
        on join(p)
          p.color = "red"
          p.size = 3
          p.hat = "crown"
          p.name = "Big " + p.name
          if p.name == "Big Bob" then p.visible = false end
        end
        """#)
        startWithBoth(game)
        XCTAssertTrue(game.takeRosterChange())
        let aliceNow = game.roster.first { $0.peerID == alice }
        XCTAssertEqual(aliceNow?.profile.bodyColor, ScriptColor.parse("red"))
        XCTAssertEqual(aliceNow?.profile.height, 3)
        XCTAssertEqual(aliceNow?.profile.hat, .crown)
        XCTAssertEqual(aliceNow?.profile.displayName, "Big Alice")
        XCTAssertEqual(game.roster.first { $0.peerID == bob }?.isHidden, true)
        XCTAssertFalse(game.takeRosterChange(), "reported once")

        game.handle(.roundStarted)
        XCTAssertEqual(game.roster.first { $0.peerID == alice }?.profile.displayName, "Big Alice",
                       "a restart gives everyone their own look back before `on join` runs again — not “Big Big Alice”")
    }

    func testBigCharactersAreBigTargets() {
        let game = game("on join(p)\n  p.give(\"rifle\")\n  if p.name == \"Bob\" then p.size = 4 end\nend")
        startWithBoth(game)
        place(game, alice, at: Vec3(0, 0, -10))
        place(game, bob, at: .zero)
        // Aimed to pass 6 m up where Bob stands: far over a normal head.
        let high = game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 4.4, 10)), from: alice, at: 1)
        XCTAssertFalse(healths(bob, high).isEmpty)
    }

    // MARK: Screen GUI

    func testALateJoinerSeesWhatEveryoneElseSees() {
        let game = game(#"""
        on start()
          ui_text("title", "Capture the flag", {at: "top", color: "red", size: "large"})
          ui_bar("time", 30, 60)
        end
        on join(p)
          p.ui_text("hello", "Hi " + p.name)
        end
        """#)
        game.addPlayer(snapshot(alice, "Alice"))
        game.handle(.roundStarted)

        let arrival = game.addPlayer(snapshot(bob, "Bob"))
        let bobSees = screen(bob, arrival)
        XCTAssertEqual(bobSees.element("title")?.color, ScriptColor.parse("red"))
        XCTAssertEqual(bobSees.element("title")?.fontSize, 28)
        XCTAssertEqual(bobSees.element("time")?.fraction, 0.5)
        XCTAssertEqual(bobSees.element("hello")?.text, "Hi Bob")
        XCTAssertTrue(arrival.allSatisfy { $0.targetPeerID == bob }, "Alice already has them")
    }

    func testFreePositionsPanelsAndHandles() {
        let game = game(#"""
        on join(p)
          let menu = p.ui_panel("menu", {x: 0.25, y: 0.75, w: 300, h: 200, bg: "#00000080"})
          p.ui_text("label", "Shop", {parent: "menu", y: 0.1, size: 30, bold: true})
          let b = p.ui_button("buy", "Buy", {parent: menu, x: 0.5, y: 0.8})
          b.text = "Buy now"
          b.layer = 5
          menu.visible = false
        end
        """#)
        let mine = screen(alice, startWithBoth(game))
        let menu = mine.element("menu")
        XCTAssertEqual(menu?.x, 0.25)
        XCTAssertEqual(menu?.width, 300)
        XCTAssertEqual(menu?.visible, false)
        XCTAssertEqual(mine.element("label")?.parent, "menu")
        XCTAssertEqual(mine.element("buy")?.parent, "menu", "a handle works as a parent too")
        XCTAssertEqual(mine.element("buy")?.text, "Buy now")
        XCTAssertEqual(mine.element("buy")?.layer, 5)
        XCTAssertTrue(mine.children(of: nil).isEmpty, "the hidden panel hides its contents")
    }

    func testRemovingAPanelRemovesWhatIsInIt() {
        let game = game(#"""
        on join(p)
          p.ui_panel("menu")
          p.ui_text("a", "A", {parent: "menu"})
          p.ui_text("b", "B")
          p.ui_remove("menu")
        end
        """#)
        let mine = screen(alice, startWithBoth(game))
        XCTAssertEqual(mine.ui.map(\.id), ["b"])
    }

    func testOnlyButtonsOnScreenCanBePressed() {
        let game = game(#"""
        on join(p)
          if p.name == "Alice" then p.ui_button("shop", "Shop") end
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

    func testTextBoxes() {
        let game = game(#"""
        on join(p)
          p.ui_input("answer", "Type the password")
        end
        on input(p, id, text)
          if text == "swordfish" then p.message("Correct!") end
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(announcements(alice, game.handle(.text(id: "answer", value: "swordfish"), from: alice, at: 1)), ["Correct!"])
        XCTAssertTrue(game.handle(.text(id: "other", value: "swordfish"), from: alice, at: 1).isEmpty)
    }

    func testChatCommands() {
        let game = game("on chat(p, text)\n  if text == \"/fly\" then p.gravity = 0.1 end\nend")
        startWithBoth(game)
        let effects = game.handleChat(from: bob, text: "/fly")
        XCTAssertEqual(screen(bob, effects).movement.gravity, 0.1, accuracy: 0.0001)
    }

    func testTheScreenHasALimit() {
        let game = game("on join(p)\n  for i in 1 to 400 do\n    p.ui_text(\"item\" + i, \"x\")\n  end\nend")
        startWithBoth(game)
        XCTAssertEqual(game.drainErrors().first?.kind, .limit)
    }

    func testBadOptionsAreExplained() {
        let game = game("on start()\n  ui_text(\"a\", \"b\", {at: \"middle\"})\nend")
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().first?.message.contains("top_left") ?? false)
    }

    // MARK: Rules, touches, leaving

    func testScoresFromScriptsTripScoreRules() {
        var world = WorldDocument(name: "Arena")
        world.rules = [EventRule(name: "Win", trigger: .scoreReached(score: 3), actions: [.endRound(message: "Winner")])]
        let game = game("on join(p)\n  if p.name == \"Bob\" then p.score = 3 end\nend", world: world)
        XCTAssertTrue(announcements(alice, startWithBoth(game)).contains("Winner"))
    }

    func testRulesStillRunWhenTheScriptDoesNotParse() {
        var world = WorldDocument(name: "Arena")
        world.rules = [EventRule(name: "Hello", trigger: .worldStart, actions: [.announce(message: "Welcome", duration: 2)])]
        let game = game("on start(\n", world: world)
        let opening = startWithBoth(game)
        XCTAssertEqual(game.compileErrors.count, 1)
        XCTAssertEqual(game.compileErrors.first?.file, "main.absc")
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
        var limits = ScriptInterpreter.Limits()
        limits.stepsPerCall = 20_000
        let game = game("on tick(dt)\n  while true do\n  end\nend", limits: limits)
        startWithBoth(game)
        game.advance(to: 0.1)
        XCTAssertEqual(game.drainErrors().first?.kind, .limit)
    }

    func testTheDefaultBudgetIsGenerous() {
        // A hundred thousand loop iterations in one event is ordinary game
        // logic now, not a runaway.
        let game = game("on start()\n  let total = 0\n  for i in 1 to 100000 do total = total + i end\n  print(total)\nend")
        startWithBoth(game)
        XCTAssertEqual(game.drainOutput(), ["5000050000"])
        XCTAssertTrue(game.drainErrors().isEmpty)
    }

    func testTimersCannotPileUpForever() {
        let game = game("on tick(dt)\n  for i in 1 to 50 do every(100, func() end) end\nend")
        startWithBoth(game)
        for step in 1...30 { game.advance(to: Double(step) * 0.1) }
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
            .ui(UIElement(id: "a", kind: .text, parent: "p", text: "Hi", x: 0.1, y: 0.9, width: 100, color: .white)),
            .ui(UIElement(id: "b", kind: .bar, value: 3, maximum: 10)),
            .removeUI(id: "a"),
            .clearUI,
            .camera(CameraSettings(mode: .fixed, distance: 3, fieldOfView: 80, position: Vec3(1, 2, 3), target: nil)),
            .shake(strength: 0.5, seconds: 1),
            .fade(color: .black, seconds: 2),
            .fade(color: nil, seconds: 0),
            .interface(controls: false, defaultUI: true),
            .equip(WeaponSpec.presets["pistol"]),
            .equip(nil),
            .ammo(current: 3, magazine: 10, reloading: true),
            .health(current: 50, maximum: 100),
            .movement(MovementScale(speed: 2, jump: 0.5, gravity: 0.3, frozen: true)),
            .launch(Vec3(0, 10, 0)),
            .face(yawDegrees: 45),
            .hitMarker(killed: true),
            .damageFlash,
            .tracer(from: Vec3(1, 2, 3), to: Vec3(4, 5, 6)),
            .chat("hello")
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
            .reload,
            .text(id: "name", value: "Mika")
        ]
        for input in inputs {
            let payload = PlayerInputPayload(peerID: alice, input: input)
            XCTAssertEqual(try JSONDecoder().decode(PlayerInputPayload.self, from: JSONEncoder().encode(payload)), payload)
        }
    }

    func testRosterEntriesFromOlderPeersStillDecode() throws {
        let snapshot = PlayerSnapshot(peerID: alice)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        json["isNPC"] = nil
        json["isHidden"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(PlayerSnapshot.self, from: old)
        XCTAssertFalse(decoded.isNPC)
        XCTAssertFalse(decoded.isHidden)
    }

    func testNamedColours() {
        XCTAssertEqual(ScriptColor.parse("red"), ScriptColor.parse("赤"))
        XCTAssertEqual(ScriptColor.parse(" Blue "), ScriptColor.parse("#3B82F6"))
        XCTAssertEqual(ScriptColor.parse("透明")?.a, 0)
        XCTAssertNil(ScriptColor.parse("bleu"))
        XCTAssertNil(ScriptColor.parse("123456"), "hex needs its #, so a typo is not silently a colour")
    }
}
