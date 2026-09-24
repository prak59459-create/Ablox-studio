import XCTest
@testable import AbloxCore

/// NPCs, building the map from a script, the world's settings and raycasts.
final class ScriptWorldTests: RuntimeTestCase {

    private func floorWorld() -> WorldDocument {
        var world = WorldDocument(name: "Arena")
        var floor = BlockData(name: "Floor", transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(100, 1, 100)))
        floor.tags = ["ground"]
        world.insert(floor)
        return world
    }

    // MARK: Touchable blocks

    func testAScriptMadeBlockIsTouchableOnlyWithABehavior() {
        let game = game(#"""
        on start()
          create_block({name: "Coin", position: {x: 0, y: 1, z: 0}, behavior: "trigger"})
          create_block({name: "Rock", position: {x: 5, y: 1, z: 0}})
        end
        on touch(p, b)
          announce(p.name + " touched " + b.name + " (" + b.behavior + ")")
        end
        """#, world: floorWorld())
        startWithBoth(game)
        let coin = game.world.blocks.first { $0.name == "Coin" }!
        let rock = game.world.blocks.first { $0.name == "Rock" }!
        XCTAssertEqual(coin.behavior, .trigger)
        XCTAssertTrue(coin.behavior.needsTouchDetection, "so the iPad reports touching it")
        XCTAssertFalse(rock.behavior.needsTouchDetection, "plain scenery is not reported")

        let touching = WorldCollider.resolve(position: Vec3(0, 0.5, 0), velocity: .zero, world: game.world, deltaTime: 0.1)
        XCTAssertTrue(touching.touchedBlockIDs.contains(coin.id))
        let effects = game.handle(.touched(peer: alice, blockID: coin.id))
        XCTAssertTrue(announcements(alice, effects).contains("Alice touched Coin (trigger)"))
    }

    func testABadBehaviorNamesTheChoices() {
        let game = game(#"""
        on start()
          create_block({name: "X", behavior: "lava"})
        end
        """#)
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().first?.message.contains("trigger") ?? false)
    }

    // MARK: NPCs

    func testNPCsWalkToWhereTheyAreSent() {
        let game = game(#"""
        let guard = nil
        on start()
          guard = create_npc({name: "Guard", position: {x: 0, y: 1, z: 0}, color: "red"})
          guard.move_to({x: 10, y: 0, z: 0})
        end
        """#, world: floorWorld())
        startWithBoth(game)
        XCTAssertTrue(game.takeRosterChange(), "a new NPC means a new roster")
        let npc = game.roster.first { $0.isNPC }
        XCTAssertEqual(npc?.profile.displayName, "Guard")
        XCTAssertEqual(npc?.profile.bodyColor, ScriptColor.parse("red"))

        for step in 1...60 { game.advance(to: Double(step) * 0.1) }
        let moved = game.roster.first { $0.isNPC }
        XCTAssertEqual(moved?.position.x ?? 0, 10, accuracy: 0.5, "walked there")
        XCTAssertEqual(moved?.position.y ?? 9, 0, accuracy: 0.1, "standing on the floor, not falling through it")
        XCTAssertFalse(game.drainNPCTransforms().isEmpty, "and everyone was told where it went")
    }

    func testNPCsFollowAndCanBeShot() {
        let game = game(#"""
        on start()
          let z = create_npc({name: "Zombie", position: {x: 0, y: 0, z: 0}, health: 30})
        end
        on join(p)
          p.give("rifle")
        end
        on death(victim, killer)
          if victim.is_npc then announce(killer.name + " got the " + victim.name) end
        end
        """#, world: floorWorld())
        startWithBoth(game)
        game.advance(to: 0.1)
        place(game, alice, at: Vec3(0, 0, -10))
        let effects = game.handle(.fire(origin: Vec3(0, 1.6, -10), direction: Vec3(0, 0, 1)), from: alice, at: 1)
        XCTAssertTrue(scripted(alice, effects).contains(.hitMarker(killed: true)))
        XCTAssertTrue(announcements(alice, effects).contains("Alice got the Zombie"))
        XCTAssertTrue(game.roster.allSatisfy { !$0.isNPC }, "a knocked-out NPC is removed")
    }

    func testNPCsCanHurtPlayers() {
        let game = game(#"""
        let z = nil
        on start()
          z = create_npc({name: "Zombie"})
        end
        on tick(dt)
          for p in players() do p.damage(10, z) end
        end
        on death(victim, killer)
          announce(victim.name + " was got by " + killer.name)
        end
        """#)
        startWithBoth(game)
        var heard: [String] = []
        for step in 1...12 { heard += announcements(alice, game.advance(to: Double(step) * 0.1)) }
        XCTAssertTrue(heard.contains("Alice was got by Zombie"))
    }

    func testAnNPCSpeaksInABubbleOverItsHead() {
        let game = game(#"""
        on start()
          let n = create_npc({name: "Nurse"})
          n.say("Next, please!")
        end
        """#)
        let effects = startWithBoth(game)
        let npc = game.roster.first { $0.isNPC }!
        XCTAssertTrue(scripted(alice, effects).contains(.say(speaker: npc.peerID, name: "Nurse", text: "Next, please!")),
                      "the line names who said it, so the bubble goes over the right head")
        XCTAssertTrue(scripted(bob, effects).contains(.say(speaker: npc.peerID, name: "Nurse", text: "Next, please!")),
                      "and everyone hears it")
    }

    func testNPCsCannotBeMovedByClients() {
        let game = game("on start()\n  create_npc({name: \"A\", position: {x: 1, y: 1, z: 1}})\nend")
        startWithBoth(game)
        let npc = game.roster.first { $0.isNPC }!
        game.updateTransform(PlayerTransformPayload(peerID: npc.peerID, position: Vec3(99, 99, 99), yawDegrees: 0))
        XCTAssertEqual(game.roster.first { $0.isNPC }?.position, Vec3(1, 1, 1))
    }

    func testNPCsAreNotPlayers() {
        let game = game("on start()\n  create_npc({})\n  print(len(players()), len(npcs()))\nend")
        startWithBoth(game)
        XCTAssertEqual(game.drainOutput(), ["2 1"])
        XCTAssertEqual(game.players.count, 2, "NPCs never count against the player limit")
    }

    func testARestartClearsNPCs() {
        let game = game("on start()\n  create_npc({})\nend")
        startWithBoth(game)
        game.handle(.roundStarted)
        XCTAssertEqual(game.roster.filter(\.isNPC).count, 1, "the new round's own NPC, not two")
    }

    // MARK: Building the map

    func testScriptsCreateChangeAndDestroyBlocks() {
        let game = game(#"""
        on start()
          let b = create_block({name: "Tower", shape: "cylinder", position: {x: 0, y: 5, z: 0}, size: {x: 2, y: 10, z: 2},
                                color: "blue", material: "neon", tags: ["tall"]})
          b.color = "red"
          b.rotation = {x: 0, y: 45, z: 0}
          let copy = b.clone()
          copy.position = {x: 10, y: 5, z: 0}
          block("Door").destroy()
          print(len(blocks("tall")), len(blocks()))
        end
        """#, world: {
            var world = WorldDocument(name: "Arena")
            world.insert(BlockData(name: "Door"))
            return world
        }())
        startWithBoth(game)
        XCTAssertEqual(game.drainOutput(), ["2 2"])
        let tower = game.world.blocks.first { $0.name == "Tower" && $0.position.x == 0 }
        XCTAssertEqual(tower?.shape, .cylinder)
        XCTAssertEqual(tower?.scale, Vec3(2, 10, 2))
        XCTAssertEqual(tower?.color, ScriptColor.parse("red"))
        XCTAssertEqual(tower?.material, .neon)
        XCTAssertNil(game.world.blocks.first { $0.name == "Door" })

        let deltas = game.drainWorldDeltas()
        XCTAssertTrue(deltas.contains { if case .remove = $0 { return true }; return false })
        XCTAssertEqual(deltas.filter { if case .insert = $0 { return true }; return false }.count, 2)
    }

    func testEveryIPadThatAppliesTheDeltasHasTheHostsMap() {
        var world = WorldDocument(name: "Arena")
        world.insert(BlockData(name: "Door"))
        let game = game(#"""
        on start()
          block("Door").destroy()
          let b = create_block({name: "Bridge", size: {x: 8, y: 0.5, z: 2}})
          b.position = {x: 4, y: 3, z: 0}
          b.color = "brown"
          world.gravity = -5
        end
        """#, world: world)
        var client = world
        startWithBoth(game)
        for delta in game.drainWorldDeltas() { delta.apply(to: &client) }
        XCTAssertEqual(client.blocks, game.world.blocks)
        XCTAssertEqual(client.environment, game.world.environment)
    }

    func testARestartPutsTheMapBack() {
        var world = WorldDocument(name: "Arena")
        let door = BlockData(name: "Door")
        world.insert(door)
        let game = game("on start()\n  if block(\"Door\") then block(\"Door\").destroy() end\n  create_block({name: \"Rubble\"})\n  world.sky = \"red\"\nend", world: world)
        startWithBoth(game)
        _ = game.drainWorldDeltas()
        game.handle(.roundStarted)
        // The second round's script removes the door again, but first the
        // original was put back.
        let deltas = game.drainWorldDeltas()
        XCTAssertTrue(deltas.contains(.insert(door)))
        XCTAssertEqual(game.world.blocks.filter { $0.name == "Rubble" }.count, 1, "last round's rubble cleared")
    }

    func testAnimatedMovesReachEveryoneWhenTheyFinish() {
        var world = WorldDocument(name: "Arena")
        let lift = BlockData(name: "Lift")
        world.insert(lift)
        let game = game("on start()\n  block(\"Lift\").move(0, 5, 0, 1)\nend", world: world)
        let opening = startWithBoth(game)
        XCTAssertTrue(reaching(alice, opening).contains(.move(blockID: lift.id, offset: Vec3(0, 5, 0), duration: 1)))
        XCTAssertEqual(game.world.block(id: lift.id)?.position, Vec3(0, 5, 0), "the host's map moves at once")
        XCTAssertTrue(game.drainWorldDeltas().isEmpty, "clients animate first")
        game.advance(to: 0.5)
        XCTAssertTrue(game.drainWorldDeltas().isEmpty)
        game.advance(to: 1.1)
        XCTAssertEqual(game.drainWorldDeltas().count, 1, "then take the end position")
    }

    func testTheWorldItself() {
        let game = game("on start()\n  world.gravity = -3\n  world.sky = \"black\"\n  world.light = 0.2\n  world.fall_height = -5\nend")
        startWithBoth(game)
        XCTAssertEqual(game.world.environment.gravity, -3)
        XCTAssertEqual(game.world.environment.skyTop, ScriptColor.parse("black"))
        XCTAssertEqual(game.world.environment.ambientIntensity, 0.2, accuracy: 0.0001)
        XCTAssertEqual(game.world.environment.killPlaneHeight, -5)
        XCTAssertTrue(game.drainWorldDeltas().contains { if case .environment = $0 { return true }; return false })
    }

    func testRaycasts() {
        var world = WorldDocument(name: "Arena")
        world.insert(BlockData(name: "Wall", transform: Transform3D(position: Vec3(0, 1, 10), scale: Vec3(10, 4, 1))))
        let game = game(#"""
        on start()
          let hit = raycast({x: 0, y: 1, z: 0}, {x: 0, y: 0, z: 1}, 50)
          print(hit.block.name, hit.distance)
          print(raycast({x: 0, y: 1, z: 0}, {x: 0, y: 0, z: -1}, 50))
        end
        """#, world: world)
        startWithBoth(game)
        XCTAssertEqual(game.drainOutput(), ["Wall 9.5", "nil"])
    }

    // MARK: Many .absc files

    func testFilesRunTogetherAndEachCanHandleTheSameEvent() {
        var world = WorldDocument(name: "Arena")
        world.scripts = [
            ScriptFile(name: "main", source: "let shared = 1\non join(p)\n  print(\"main \" + p.name)\nend"),
            ScriptFile(name: "ui.absc", source: "on join(p)\n  print(\"ui \" + p.name + \" \" + shared)\nend"),
            ScriptFile(name: "off", source: "on join(p)\n  print(\"never\")\nend", isEnabled: false)
        ]
        let game = GameRuntime(world: world)
        game.addPlayer(snapshot(alice, "Alice"))
        game.handle(.roundStarted)
        XCTAssertEqual(game.drainOutput(), ["main Alice", "ui Alice 1"], "in file order, sharing globals, skipping switched-off files")
    }

    func testErrorsNameTheirFile() {
        let files = [
            ScriptFile(name: "main", source: "on start()\nend"),
            ScriptFile(name: "broken", source: "\n\nlet = 3"),
            ScriptFile(name: "also broken", source: "on start(\n")
        ]
        let errors = GameRuntime.check(files)
        XCTAssertEqual(errors.map(\.file), ["broken.absc", "also broken.absc"])
        XCTAssertEqual(errors.first?.line, 3)
        XCTAssertTrue(errors.first?.description.contains("broken.absc") ?? false)

        var world = WorldDocument(name: "Arena")
        world.scripts = [ScriptFile(name: "a", source: "on start()\nend"),
                         ScriptFile(name: "b", source: "on start()\n  let x = nil\n  print(x.y)\nend")]
        let game = GameRuntime(world: world)
        game.handle(.roundStarted)
        let runtime = game.drainErrors().first
        XCTAssertEqual(runtime?.file, "b.absc")
        XCTAssertEqual(runtime?.line, 3)
    }

    func testFileNamesAreCleaned() {
        XCTAssertEqual(ScriptFile.cleanName("main"), "main.absc")
        XCTAssertEqual(ScriptFile.cleanName("Main.ABSC"), "Main.absc")
        XCTAssertEqual(ScriptFile.cleanName("../../etc/passwd"), "passwd.absc")
        XCTAssertEqual(ScriptFile.cleanName("   "), "main.absc")
        XCTAssertEqual(ScriptFile.cleanName("ゲーム"), "ゲーム.absc")
        let existing = [ScriptFile(name: "main", source: ""), ScriptFile(name: "main 2", source: "")]
        XCTAssertEqual(ScriptFile.uniqueName("main", among: existing), "main 3.absc")
    }

    func testWorldsFromEveryVersionStillOpen() throws {
        // Before scripts.
        let old = WorldDocument(name: "Old")
        let data = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("scripts"))
        XCTAssertEqual(try JSONDecoder().decode(WorldDocument.self, from: data).scripts, [])

        // The first scripting build: one "script" string.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["script"] = "on start()\nend"
        let legacy = try JSONDecoder().decode(WorldDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.scripts.map(\.name), ["main.absc"])
        XCTAssertEqual(legacy.scripts.first?.source, "on start()\nend")

        // Now.
        var current = old
        current.scripts = [ScriptFile(name: "a", source: "print(1)"), ScriptFile(name: "b", source: "", isEnabled: false)]
        XCTAssertEqual(try JSONDecoder().decode(WorldDocument.self, from: JSONEncoder().encode(current)), current)
    }

    func testScriptsTravelAsADelta() throws {
        var world = WorldDocument(name: "Co-edit")
        let files = [ScriptFile(name: "main", source: "on start()\nend")]
        let delta = WorldDelta.scriptsReplaced(files)
        let restored = try JSONDecoder().decode(WorldDelta.self, from: JSONEncoder().encode(delta))
        XCTAssertEqual(restored, delta)
        XCTAssertTrue(restored.apply(to: &world))
        XCTAssertEqual(world.scripts, files)
    }

    // MARK: The game list

    func testListingsCanCarryScriptFiles() {
        var listing = GameListing(id: "zombies", title: "Zombies", world: "games/zombies/world.ablox",
                                  scripts: ["games/zombies/main.absc", "games/zombies/ui.absc"])
        XCTAssertNil(listing.rejection())
        let urls = CatalogueSource.default.scriptURLs(for: listing)
        XCTAssertEqual(urls.map(\.name), ["main.absc", "ui.absc"])
        XCTAssertEqual(urls.first?.url.absoluteString,
                       "https://raw.githubusercontent.com/prak59459-create/AbloxGames/main/games/zombies/main.absc")

        listing.scripts = ["../secret.absc"]
        XCTAssertEqual(listing.rejection(), .invalidPath(field: "scripts", value: "../secret.absc"))
        listing.scripts = ["games/zombies/main.swift"]
        XCTAssertNotNil(listing.rejection(), "only .absc files")
    }

    func testOldIndexesWithoutScriptsStillDecode() throws {
        let json = #"{"catalogueVersion":1,"updatedAt":"2026-01-01T00:00:00Z","games":[{"id":"a","title":"A","author":"","summary":"","world":"a/world.ablox","tags":[],"blockCount":1,"maxPlayers":4,"schemaVersion":1,"updatedAt":"2026-01-01T00:00:00Z"}]}"#
        let catalogue = try GameCatalogue.decode(indexData: Data(json.utf8))
        XCTAssertNil(catalogue.games.first?.scripts)
    }
}

/// Every sample Studio offers has to work the moment it is inserted.
final class ScriptSampleTests: XCTestCase {

    private func world(with sample: ScriptSample) -> WorldDocument {
        var world = WorldDocument(name: "Sample")
        world.insert(BlockData(name: "Floor", transform: Transform3D(position: Vec3(0, -0.5, 0), scale: Vec3(100, 1, 100))))
        world.scripts = [ScriptFile(name: sample.fileName, source: sample.source)]
        return world
    }

    func testEverySampleRunsCleanly() {
        for sample in ScriptSamples.all {
            let report = GameRuntime.testRun(world: world(with: sample), seconds: 3)
            XCTAssertEqual(report.problems, [], "\(sample.id): \(report.problems.map(\.description))")
            XCTAssertFalse(sample.title.isEmpty)
            XCTAssertTrue(sample.fileName.hasSuffix(".absc"))
        }
    }

    func testSampleIDsAreUnique() {
        let ids = ScriptSamples.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTheDuelSampleSetsUpAShooter() {
        let notes = GameRuntime.testRun(world: world(with: ScriptSamples.duel)).notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("rifle"), notes)
        XCTAssertTrue(notes.contains("Knockouts: 0"), notes)
    }

    func testTheZombieSampleSpawnsAWave() {
        let notes = GameRuntime.testRun(world: world(with: ScriptSamples.zombies)).notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("NPCs: 3"), notes)
    }

    func testTheObstacleSampleBuildsItsCourse() {
        let notes = GameRuntime.testRun(world: world(with: ScriptSamples.obstacleCourse)).notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("Blocks created: 13"), notes)
    }

    func testTheMenuSampleHidesTheControls() {
        let notes = GameRuntime.testRun(world: world(with: ScriptSamples.menuAndShop)).notes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("Button: Play"), notes)
    }

    func testATestRunReportsSyntaxErrorsAndStops() {
        var world = WorldDocument(name: "Broken")
        world.scripts = [ScriptFile(name: "main", source: "on start(\n")]
        let report = GameRuntime.testRun(world: world)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertTrue(report.notes.isEmpty)
    }

    func testATestRunReportsPrintedLines() {
        var world = WorldDocument(name: "Hello")
        world.scripts = [ScriptFile(name: "main", source: "on join(p)\n  print(\"hello \" + p.name)\nend")]
        XCTAssertEqual(GameRuntime.testRun(world: world).output.count, 2, "one per player")
    }
}

/// Folding host effects into what one player's screen shows.
final class ScriptedPlayerStateTests: XCTestCase {

    func testScreenItemsKeepTheirPlaceWhenUpdated() {
        var state = ScriptedPlayerState()
        state.apply(.ui(UIElement(id: "a", kind: .text, text: "1")))
        state.apply(.ui(UIElement(id: "b", kind: .text, text: "2")))
        state.apply(.ui(UIElement(id: "a", kind: .text, text: "3")))
        XCTAssertEqual(state.ui.map(\.id), ["a", "b"])
        XCTAssertEqual(state.element("a")?.text, "3")
        state.apply(.removeUI(id: "a"))
        XCTAssertEqual(state.ui.map(\.id), ["b"])
        state.apply(.clearUI)
        XCTAssertTrue(state.ui.isEmpty)
    }

    func testLayersDecideTheDrawingOrder() {
        var state = ScriptedPlayerState()
        state.apply(.ui(UIElement(id: "top", kind: .text, layer: 2)))
        state.apply(.ui(UIElement(id: "bottom", kind: .text, layer: -1)))
        state.apply(.ui(UIElement(id: "middle", kind: .text)))
        XCTAssertEqual(state.children(of: nil).map(\.id), ["bottom", "middle", "top"])
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

    func testEachHitAndFadeIsCounted() {
        var state = ScriptedPlayerState()
        state.apply(.hitMarker(killed: false))
        state.apply(.hitMarker(killed: true))
        state.apply(.damageFlash)
        state.apply(.fade(color: .black, seconds: 1))
        state.apply(.fade(color: .black, seconds: 1))
        XCTAssertEqual(state.hitMarkerCount, 2)
        XCTAssertTrue(state.lastHitWasKnockout)
        XCTAssertEqual(state.damageFlashCount, 1)
        XCTAssertEqual(state.fade.serial, 2, "the same fade twice still animates twice")
    }

    func testPresetsSitInsideTheEdge() {
        var element = UIElement(id: "a", kind: .text)
        element.place(at: UIElement.presets["bottom_right"]!)
        XCTAssertEqual(element.x, 1)
        XCTAssertEqual(element.pivotX, 1)
        XCTAssertEqual(element.offsetX, -16)
        XCTAssertEqual(element.offsetY, -16)
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
        for name in GameRuntime.gameAPINames + ScriptInterpreter.standardLibraryNames {
            XCTAssertNotNil(allCode.range(of: "\\b\(name)\\b", options: .regularExpression), "\(name) is missing")
        }
    }

    func testEveryMemberIsListed() {
        for name in GameRuntime.characterMemberNames + GameRuntime.playerOnlyMemberNames {
            XCTAssertTrue(allCode.contains("p.\(name)"), "p.\(name) is missing")
        }
        for name in GameRuntime.npcOnlyMemberNames {
            XCTAssertTrue(allCode.contains("n.\(name)"), "n.\(name) is missing")
        }
        for name in GameRuntime.blockMemberNames where !["id", "x", "y", "z"].contains(name) {
            XCTAssertTrue(allCode.contains("b.\(name)"), "b.\(name) is missing")
        }
        for name in GameRuntime.worldMemberNames {
            XCTAssertTrue(allCode.contains("world.\(name)"), "world.\(name) is missing")
        }
        for name in GameRuntime.uiOptionNames {
            XCTAssertNotNil(allCode.range(of: "\\b\(name)\\b", options: .regularExpression), "option \(name) is missing")
        }
    }
}

/// The standard library's newer half: maths, positions and lists.
final class ScriptLibraryTests: XCTestCase {

    private func run(_ source: String) throws -> [String] {
        let interpreter = ScriptInterpreter(program: try ScriptParser.parse(source))
        try interpreter.start()
        return interpreter.drainOutput()
    }

    func testPositionsAreArithmetic() throws {
        XCTAssertEqual(try run("let a = {x: 1, y: 2, z: 3}\nlet b = a + {x: 1, y: 1, z: 1} * 2\nprint(b.x, b.y, b.z)"), ["3 4 5"])
        XCTAssertEqual(try run("let v = -vec(1, 0, 0) / 2\nprint(v.x)"), ["-0.5"])
        XCTAssertEqual(try run("print(magnitude(vec(3, 4, 0)), dot(vec(1, 0, 0), vec(0, 1, 0)))"), ["5 0"])
        XCTAssertEqual(try run("let n = normalize(vec(0, 0, 9))\nprint(n.z)"), ["1"])
        XCTAssertEqual(try run("let c = cross(vec(1, 0, 0), vec(0, 1, 0))\nprint(c.z)"), ["1"])
    }

    func testMaths() throws {
        XCTAssertEqual(try run("print(pow(2, 10), round(3.14159, 2), fixed(2, 1), sign(-4))"), ["1024 3.14 2.0 -1"])
        XCTAssertEqual(try run("print(round(atan2(1, 0)), round(tan(45)), round(pi, 3))"), ["90 1 3.142"])
        XCTAssertEqual(try run("print(lerp(0, 10, 0.25))"), ["2.5"])
    }

    func testLists() throws {
        XCTAssertEqual(try run("print(join(sort([3, 1, 2]), \",\"))"), ["1,2,3"])
        XCTAssertEqual(try run("print(join(sort([1, 3, 2], func(a, b) return a > b end), \",\"))"), ["3,2,1"])
        XCTAssertEqual(try run("print(join(map([1, 2], func(x) return x * 10 end), \",\"))"), ["10,20"])
        XCTAssertEqual(try run("print(join(filter(range(1, 6), func(x) return x % 2 == 0 end), \",\"))"), ["2,4,6"])
        XCTAssertEqual(try run("print(sum([1, 2, 3]), index_of([5, 6], 6), join(slice([1, 2, 3, 4], 2, 3), \",\"))"), ["6 2 2,3"])
        XCTAssertEqual(try run("let l = [1, 3]\ninsert(l, 2, 2)\nprint(join(reverse(l), \",\"))"), ["3,2,1"])
        XCTAssertEqual(try run("let a = [1]\nlet b = copy(a)\nappend(b, 2)\nprint(len(a), len(b))"), ["1 2"])
    }

    func testText() throws {
        XCTAssertEqual(try run("print(replace(\"a-b-c\", \"-\", \"+\"), starts_with(\"hello\", \"he\"), ends_with(\"hello\", \"x\"))"),
                       ["a+b+c true false"])
        XCTAssertEqual(try run("print(slice(\"hello\", 2, 4), index_of(\"hello\", \"l\"))"), ["ell 3"])
    }

    func testSortingMixedValuesIsAnError() {
        XCTAssertThrowsError(try run("print(sort([1, \"a\"]))"))
    }
}
