import XCTest
@testable import AbloxCore

/// Weather, the day, the sky, particles, sounds, music, moving platforms,
/// swimming and climbing — the arithmetic behind what `Engine` draws.
final class WorldFeaturesTests: XCTestCase {

    // MARK: The day

    func testHoursWrapRoundTheClock() {
        XCTAssertEqual(DayCycle.hour(start: 23, dayLengthMinutes: 0, elapsed: 500), 23)
        XCTAssertEqual(DayCycle.hour(start: 22, dayLengthMinutes: 24, elapsed: 3 * 60), 1, accuracy: 0.001)
        XCTAssertEqual(DayCycle.hour(start: -2, dayLengthMinutes: 0, elapsed: 0), 22)
        XCTAssertEqual(DayCycle.hour(start: .nan, dayLengthMinutes: 0, elapsed: 0), 12)
    }

    func testTheSunIsHighAtNoonAndGoneAtMidnight() {
        XCTAssertEqual(DayCycle.sunHeight(hour: 12), 1, accuracy: 0.001)
        XCTAssertEqual(DayCycle.sunHeight(hour: 0), -1, accuracy: 0.001)
        XCTAssertTrue(DayCycle.isNight(hour: 1))
        XCTAssertFalse(DayCycle.isNight(hour: 13))
        XCTAssertEqual(DayCycle.light(hour: 12), 1, accuracy: 0.001)
        XCTAssertEqual(DayCycle.light(hour: 0), 0.25, accuracy: 0.001)
        XCTAssertLessThan(DayCycle.sunPitch(hour: 12), DayCycle.sunPitch(hour: 7), "higher at noon: more negative pitch")
    }

    func testTheSkyKeepsItsColoursByDayAndDarkensAtNight() {
        let top = ColorRGBA(r: 0.3, g: 0.6, b: 1)
        let bottom = ColorRGBA(r: 0.7, g: 0.85, b: 1)
        let noon = DayCycle.sky(hour: 12, top: top, bottom: bottom)
        XCTAssertEqual(noon.top, top)
        XCTAssertEqual(noon.bottom, bottom)
        let midnight = DayCycle.sky(hour: 0, top: top, bottom: bottom)
        XCTAssertLessThan(midnight.top.b, 0.2)
    }

    func testTheDayIsCountedFromWhenItStarted() {
        var environment = EnvironmentSettings(timeOfDay: 6, dayLengthMinutes: 24)
        XCTAssertEqual(environment.hour(atWallClock: 1_000), 6, "not started yet: the start hour")
        environment.dayEpoch = 1_000
        XCTAssertEqual(environment.hour(atWallClock: 1_000 + 60)!, 7, accuracy: 0.001)
        XCTAssertNil(EnvironmentSettings().hour(atWallClock: 5), "a world without a day keeps its sun")
    }

    // MARK: Moving platforms

    func testAMovingPlatformWaitsGoesWaitsAndComesBack() {
        let gimmick = GimmickSettings(moveOffset: Vec3(0, 6, 0), moveSeconds: 2, movePause: 1)
        XCTAssertEqual(MovingParts.offset(for: gimmick, at: 0.5), .zero)
        let halfway = MovingParts.offset(for: gimmick, at: 2)
        XCTAssertEqual(halfway.y, 3, accuracy: 0.001)
        XCTAssertEqual(MovingParts.offset(for: gimmick, at: 3.5).y, 6, accuracy: 0.001)
        XCTAssertEqual(MovingParts.offset(for: gimmick, at: 5).y, 3, accuracy: 0.001)
        XCTAssertEqual(MovingParts.offset(for: gimmick, at: 6 + 0.5), .zero, "the cycle repeats")
        XCTAssertEqual(MovingParts.offset(for: gimmick, at: .infinity), .zero)
    }

    func testPlacingMovesOnlyMovingPlatforms() {
        var world = WorldDocument(name: "Lift")
        var lift = BlockData(name: "Lift", behavior: .elevator)
        lift.gimmick = GimmickSettings(moveOffset: Vec3(4, 0, 0), moveSeconds: 1, movePause: 0)
        let wall = BlockData(name: "Wall")
        world.blocks = [lift, wall]
        let placed = MovingParts.placed(world, at: 1)
        XCTAssertEqual(placed.block(id: lift.id)?.position.x ?? 0, lift.position.x + 4, accuracy: 0.001)
        XCTAssertEqual(placed.block(id: wall.id)?.position, wall.position)
    }

    // MARK: Swimming and climbing

    func testWaterIsSwumInAndLaddersAreClimbed() {
        var world = WorldDocument(name: "Pool")
        var water = BlockData(name: "Water")
        water.material = .water
        water.position = Vec3(0, 1, 0)
        water.scale = Vec3(10, 4, 10)
        var ladder = BlockData(name: "Ladder", behavior: .ladder)
        ladder.position = Vec3(20, 2, 0)
        ladder.scale = Vec3(1, 4, 0.2)
        world.blocks = [water, ladder]
        let index = WorldIndex(world: world)
        let body = CharacterBody(radius: 0.4, height: 1.8)

        XCTAssertEqual(Surroundings.find(at: Vec3(0, 0, 0), body: body, in: index), .water(surface: 3))
        XCTAssertEqual(Surroundings.find(at: Vec3(20, 0.5, 0.4), body: body, in: index), .ladder)
        XCTAssertEqual(Surroundings.find(at: Vec3(50, 0, 0), body: body, in: index), .normal)
        XCTAssertFalse(index.entry(for: water.id)?.hasCollision ?? true, "water holds nobody up")
    }

    func testClimbingGoesUpAndSwimmingSinksSlowly() {
        let snapshot = PlayerSnapshot(peerID: PeerID(), profile: .default, position: .zero)
        var input = MovementInput()
        input.stick = Vec3(0, 0, 1)
        let climb = CharacterSolver.step(snapshot: snapshot, input: input, surroundings: .ladder, deltaTime: 0.1)
        XCTAssertGreaterThan(climb.velocity.y, 0)

        var sinking = snapshot
        sinking.velocity = Vec3(0, -20, 0)
        let swim = CharacterSolver.step(snapshot: sinking, input: MovementInput(), surroundings: .water(surface: 5), deltaTime: 0.1)
        XCTAssertGreaterThanOrEqual(swim.velocity.y, -2.5)
    }

    // MARK: Sounds and music

    func testEveryCueHasTones() {
        for cue in SoundCue.allCases {
            XCTAssertFalse(cue.tones.isEmpty, "\(cue) makes no sound")
            XCTAssertTrue(cue.tones.allSatisfy { $0.duration > 0 && $0.frequency > 0 && $0.volume <= 1 })
        }
    }

    func testMusicLoopsAndStaysInTune() {
        XCTAssertEqual(MusicNote(midi: 69, steps: 1, voice: .lead, velocity: 1).frequency, 440, accuracy: 0.01)
        for track in MusicTrack.allCases {
            XCTAssertEqual(track.loopLength, 32)
            XCTAssertEqual(track.notes(at: 0), track.notes(at: track.loopLength))
            XCTAssertTrue(track.notes(at: 0).contains { $0.voice == .bass })
            for step in 0..<track.loopLength {
                XCTAssertTrue(track.notes(at: step).allSatisfy { (20...110).contains($0.midi) }, "\(track) step \(step)")
            }
            XCTAssertGreaterThan(track.stepSeconds, 0.1)
        }
    }

    func testSoundAndMusicRequestsAreKeptInRange() {
        let loud = SoundPlay(name: "coin", volume: 9, pitch: 100)
        XCTAssertEqual(loud.volume, 1)
        XCTAssertEqual(loud.pitch, 4)
        XCTAssertEqual(MusicPlay(track: "calm", volume: .nan).volume, 1)
        XCTAssertEqual(ParticleBurst(kind: .fire, position: .zero, amount: 10_000, seconds: 1_000).amount, ParticleBurst.maximumAmount)
    }

    // MARK: Pictures

    func testOnlySmallPicturesAreKept() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
        XCTAssertTrue(WorldImage(name: "Poster", data: png).isAcceptable)
        XCTAssertFalse(WorldImage(name: "Text", data: Data("hello world".utf8)).isAcceptable)
        XCTAssertFalse(WorldImage(name: "Huge", data: png + Data(count: WorldImage.maximumBytes)).isAcceptable)
    }

    // MARK: Leaderboards

    func testALeaderboardKeepsEachPlayersBest() {
        var board = Leaderboard(title: "Coins")
        XCTAssertTrue(board.submit(name: "Mika", value: 10))
        XCTAssertTrue(board.submit(name: "Ren", value: 30))
        XCTAssertFalse(board.submit(name: "Mika", value: 5), "a worse score changes nothing")
        XCTAssertEqual(board.rank(of: "Ren"), 1)
        XCTAssertEqual(board.rank(of: "Mika"), 2)

        var fastest = Leaderboard(title: "Fastest", lowerIsBetter: true)
        fastest.submit(name: "Mika", value: 40)
        fastest.submit(name: "Ren", value: 35)
        XCTAssertEqual(fastest.rank(of: "Ren"), 1)
        for n in 0..<20 { fastest.submit(name: "P\(n)", value: Double(n)) }
        XCTAssertEqual(fastest.rows.count, Leaderboard.keptRows)
    }

    func testLeaderboardsAreKeptOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LeaderboardStore(directory: directory)
        let world = UUID()
        var board = Leaderboard(title: "Coins")
        board.submit(name: "Mika", value: 12)
        store.save(["coins": board], worldID: world)
        XCTAssertEqual(store.load(worldID: world)["coins"]?.rows.first?.value, 12)
        store.delete(worldID: world)
        XCTAssertTrue(store.load(worldID: world).isEmpty)
    }

    // MARK: The runtime's own buttons

    func testReservedButtonsRoundTrip() {
        let buttons: [ReservedButton] = [.use(item: "Key"), .choose(dialog: "abc", index: 2), .buy(shop: "s1", item: "Big: Sword"),
                                         .closeDialog, .closeShop, .closeLeaderboard, .exitVehicle]
        for button in buttons {
            XCTAssertEqual(ReservedButton(id: button.id), button)
        }
        XCTAssertNil(ReservedButton(id: "play"))
        XCTAssertNil(ReservedButton(id: "__nonsense"))
    }

    // MARK: Worlds

    func testOnlyWorldsUsingNewFeaturesNeedTheNewFormat() throws {
        var plain = WorldDocument(name: "Plain")
        plain.blocks = [BlockData(name: "Floor")]
        XCTAssertEqual(plain.neededSchemaVersion, 1)

        var rainy = plain
        rainy.environment.weather = .rain
        XCTAssertEqual(rainy.neededSchemaVersion, 2)

        var brick = plain
        brick.blocks[0].material = .brick
        XCTAssertEqual(brick.neededSchemaVersion, 2)

        var lift = plain
        lift.blocks[0].behavior = .elevator
        XCTAssertEqual(lift.neededSchemaVersion, 2)
    }

    func testNewEnvironmentSettingsSurviveSaving() throws {
        var world = WorldDocument(name: "Night")
        world.environment.weather = .storm
        world.environment.timeOfDay = 21
        world.environment.dayLengthMinutes = 12
        world.environment.skyStyle = .aurora
        world.environment.screenEffect = .retro
        world.environment.shadows = false
        world.environment.music = .spooky
        world.environment.dayEpoch = 1234
        var torch = BlockData(name: "Torch")
        torch.particles = .fire
        world.blocks = [torch]
        let decoded = try WorldDocument.decoded(from: world.encodedForFile())
        XCTAssertEqual(decoded.environment, world.environment)
        XCTAssertEqual(decoded.blocks.first?.particles, .fire)
    }

    func testTheSkyDomeFacesInward() {
        let sphere = MeshGeometry.sphere(radius: 1, rings: 4, segments: 6)
        let dome = sphere.insideOut
        XCTAssertEqual(dome.triangleCount, sphere.triangleCount)
        XCTAssertEqual(dome.normals.first.map { $0 * -1 }, sphere.normals.first)
        XCTAssertEqual(Array(dome.indices.prefix(3)), [sphere.indices[0], sphere.indices[2], sphere.indices[1]])
    }
}

/// The ready-made parts, played headlessly.
final class PartsRuntimeTests: RuntimeTestCase {

    private func buttonPress(_ game: GameRuntime, _ button: ReservedButton, at time: Double = 1) -> [GameRuntime.Effect] {
        game.handle(.button(id: button.id), from: alice, at: time)
    }

    func testThingsCarriedAreShownAndUsed() {
        let game = game("""
        on join(p)
          p.give_item("Key", 2, "🔑")
        end
        on use(p, item)
          p.take_item(item)
          chat(p.name + " used " + item)
        end
        """)
        let opening = startWithBoth(game)
        XCTAssertEqual(screen(alice, opening).inventory, [InventoryItem(name: "Key", icon: "🔑", count: 2)])
        let used = buttonPress(game, .use(item: "Key"))
        XCTAssertEqual(announcements(alice, used), ["Alice used Key"])
        XCTAssertEqual(screen(alice, used).inventory.first?.count, 1)
        XCTAssertTrue(game.drainErrors().isEmpty)
    }

    func testAConversationTakesAnAnswer() {
        let game = game("""
        on join(p)
          p.dialog("Baker", "Bread?", ["Yes", "No"])
        end
        on choice(p, answer, n)
          chat(answer + " " + n)
        end
        """)
        let opening = startWithBoth(game)
        guard let dialog = screen(alice, opening).dialog else { return XCTFail("no dialog") }
        XCTAssertEqual(dialog.choices, ["Yes", "No"])
        let answered = buttonPress(game, .choose(dialog: dialog.id, index: 1))
        XCTAssertEqual(announcements(alice, answered), ["No 2"])
        XCTAssertTrue(buttonPress(game, .choose(dialog: dialog.id, index: 0)).isEmpty, "only once")
    }

    func testAShopTakesTheMoney() {
        let game = game("""
        on join(p)
          p.coins = 60
          p.shop("Smith", [{name: "Sword", price: 50}, {name: "Castle", price: 900}])
        end
        on buy(p, item, price)
          chat(item + " " + p.coins)
        end
        """)
        let opening = startWithBoth(game)
        guard let shop = screen(alice, opening).shop else { return XCTFail("no shop") }
        XCTAssertEqual(shop.balance, 60)
        XCTAssertTrue(announcements(alice, buttonPress(game, .buy(shop: shop.id, item: "Castle"))).contains(L("Not enough {}.", L("coins"))))
        XCTAssertEqual(announcements(alice, buttonPress(game, .buy(shop: shop.id, item: "Sword"))), ["Sword 10"])
    }

    func testCountdownsRunTheirHandler() {
        let game = game("""
        on start()
          countdown(5, "Round")
        end
        on countdown(label, p)
          chat(label + " over")
        end
        """)
        let opening = startWithBoth(game)
        XCTAssertEqual(screen(alice, opening).countdown?.seconds, 5)
        XCTAssertTrue(announcements(alice, game.advance(to: 3)).isEmpty)
        XCTAssertEqual(announcements(alice, game.advance(to: 6)), ["Round over"])
    }

    func testLeaderboardsRankAndAreHandedToTheHost() {
        let game = game("""
        on chat(p, text)
          let place = leaderboard("coins", p, num(text))
          chat(p.name + " is " + place)
        end
        """)
        startWithBoth(game)
        XCTAssertEqual(announcements(alice, game.handleChat(from: alice, text: "30")).last, "Alice is 1")
        XCTAssertEqual(announcements(bob, game.handleChat(from: bob, text: "50")).last, "Bob is 1")
        XCTAssertEqual(game.takeLeaderboardsIfChanged()?["coins"]?.rows.map(\.name), ["Bob", "Alice"])
        XCTAssertNil(game.takeLeaderboardsIfChanged(), "handed over once")
    }

    func testTheWorldsWeatherAndTimeCanBeSet() {
        let game = game("""
        on start()
          world.weather = "snow"
          world.time = 18
          world.day_length = 10
          world.music = "calm"
          block("Torch").particles = "fire"
          print(world.weather, block("Torch").particles)
        end
        """, world: {
            var world = WorldDocument(name: "Camp")
            world.blocks = [BlockData(name: "Torch")]
            return world
        }())
        game.wallClock = { 50_000 }
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().isEmpty)
        XCTAssertEqual(game.drainOutput(), ["snow fire"])
        let environment = game.world.environment
        XCTAssertEqual(environment.weather, .snow)
        XCTAssertEqual(environment.music, .calm)
        XCTAssertEqual(environment.hour(atWallClock: 50_000)!, 18, accuracy: 0.01)
        XCTAssertEqual(environment.hour(atWallClock: 50_000 + 60)!, 20.4, accuracy: 0.01, "a tenth of a day later")
        XCTAssertEqual(game.world.blocks.first?.particles, .fire)
    }

    func testABlockCanCarryFloatingWords() {
        let game = game("""
        on start()
          let sign = block("Sign")
          sign.label = "Shop\\nOpen"
          print(sign.label)
          let pet = create_block({name: "Pet", position: {x: 0, y: 1, z: 0}, label_size: 2,
                                  label: [{text: "Rare", color: "#3B82F6"}, "Pizza Cat", {text: "$15/s", color: "#22C55E"}, "4", "5"]})
          pet.label_height = 99
          print(pet.label_size, pet.label_height, len(split(pet.label, "\\n")))
          sign.label = nil
          print(sign.label)
        end
        """, world: {
            var world = WorldDocument(name: "Shops")
            world.blocks = [BlockData(name: "Sign")]
            return world
        }())
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().isEmpty, "\(game.drainErrors())")
        XCTAssertEqual(game.drainOutput(), ["Shop\nOpen", "2 40 4", "nil"])
        let pet = game.world.blocks.first { $0.name == "Pet" }?.label
        XCTAssertEqual(pet?.lines.map(\.text), ["Rare", "Pizza Cat", "$15/s", "4"], "four lines at most")
        XCTAssertEqual(pet?.lines.first?.color, ColorRGBA(hex: "#3B82F6"))
        XCTAssertEqual(pet?.height, BlockLabel.Limits.heights.upperBound, "held to its limits")
        XCTAssertNil(game.world.blocks.first { $0.name == "Sign" }?.label)
    }

    func testFloatingWordsSurviveSavingAndOlderWorldsReadTheSame() throws {
        var world = WorldDocument(name: "Signs")
        var sign = BlockData(name: "Sign")
        sign.label = BlockLabel(lines: [BlockLabel.Line(text: "Welcome", color: ColorRGBA(r: 1, g: 0.8, b: 0))], height: 2, size: 1.5, range: 80)
        world.blocks = [sign, BlockData(name: "Plain")]
        let decoded = try WorldDocument.decoded(from: world.encodedForFile())
        XCTAssertEqual(decoded.blocks.first?.label, sign.label)
        XCTAssertNil(decoded.blocks.last?.label, "a block without words has none")
        // Words written by hand are held to the same limits.
        let wild = try JSONDecoder().decode(BlockLabel.self, from: Data(#"{"lines":[{"text":"a","color":{"r":1,"g":1,"b":1,"a":1}}],"height":-5,"size":99,"range":1}"#.utf8))
        XCTAssertEqual(wild.height, 0)
        XCTAssertEqual(wild.size, BlockLabel.Limits.sizes.upperBound)
        XCTAssertEqual(wild.range, BlockLabel.Limits.ranges.lowerBound)
    }

    func testBlocksHangFromOthersAndMoveByThemselves() {
        let game = game("""
        on start()
          let root = create_block({name: "Pet", position: {x: 10, y: 1, z: 0}, size: 1, animation: "dance", animation_speed: 2})
          let head = create_block({name: "Head", parent: root, position: {x: 0, y: 1, z: 0}, size: 0.5, animation_speed: 9})
          print(head.parent.name, root.animation, root.animation_speed, head.animation, head.animation_speed)
          print(head.x, head.y)
          root.move({x: 5, y: 0, z: 0})
          print(head.x)
          root.animation = nil
          print(root.animation)
          root.destroy()
          print(len(blocks("Head")))
        end
        """)
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().isEmpty, "\(game.drainErrors())")
        XCTAssertEqual(game.drainOutput(), ["Pet dance 2 sway 5", "10 2", "15", "nil", "0"])
    }

    func testAnimationsArePlainNumbersOnEveryIPad() {
        let dance = BlockAnimation(kind: .dance)
        let a = dance.pose(at: 1, phase: 0)
        let b = dance.pose(at: 1, phase: 0.5)
        XCTAssertNotEqual(a.degrees, b.degrees, "two pets on the same dance are not in step")
        XCTAssertEqual(BlockAnimation(kind: .spin, speed: 99).speed, BlockAnimation.speeds.upperBound)
        let pulse = BlockAnimation(kind: .pulse).pose(at: 0.3, phase: 0)
        XCTAssertEqual(pulse.degrees, Vec3(0, 0, 0), "a pulse never turns")
        XCTAssertLessThan(abs(pulse.stretch.x - 1), 0.07)
    }

    func testMisspelledPartsSayWhatIsAvailable() {
        let game = game("""
        on start()
          particles("fireworks", {x: 0, y: 0, z: 0})
        end
        """)
        startWithBoth(game)
        XCTAssertTrue(game.drainErrors().first?.message.contains("confetti") ?? false)
    }
}
