import XCTest
@testable import AbloxCore

/// Saved game data: the values, their limits, the files on the iPad, and the
/// script API that reads and writes them.
final class GameSaveTests: RuntimeTestCase {

    // MARK: Values

    func testSavedValuesAreWrittenAsPlainJSON() throws {
        let data = SaveData(["coins": .number(120), "name": .string("Mika"), "vip": .bool(true),
                             "best": .list([.number(3), .number(1)]), "pets": .map(["cat": .number(2)])])
        let json = String(decoding: try JSONEncoder.sorted.encode(data), as: UTF8.self)
        XCTAssertEqual(json, #"{"best":[3,1],"coins":120,"name":"Mika","pets":{"cat":2},"vip":true}"#)
        XCTAssertEqual(try JSONDecoder().decode(SaveData.self, from: Data(json.utf8)), data)
    }

    func testAListKeepsItsEmptySlots() throws {
        let data = SaveData(["best": .list([.number(3), .null, .number(5)]), "gone": .null])
        XCTAssertNil(data["gone"])
        let json = String(decoding: try JSONEncoder.sorted.encode(data), as: UTF8.self)
        XCTAssertEqual(json, #"{"best":[3,null,5]}"#)
        XCTAssertEqual(try JSONDecoder().decode(SaveData.self, from: Data(json.utf8)), data)

        let game = game(#"""
        on loaded(p)
          let b = p.saved.best
          print(len(b) + " " + (b[2] == nil) + " " + b[3])
          p.save("best", [1, nil, nil, 4])
        end
        """#)
        game.addPlayer(snapshot(alice, "Alice"))
        game.handle(.roundStarted)
        game.handle(.saved(data), from: alice, at: 0.5)
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        XCTAssertEqual(game.drainOutput(), ["3 true 5"])
        let sent = scripted(alice, game.advance(to: 2)).compactMap { if case let .store(d) = $0 { return d }; return nil }
        XCTAssertEqual(sent.first?["best"], .list([.number(1), .null, .null, .number(4)]))
    }

    func testTrueStaysABoolAndOneStaysANumber() throws {
        let decoded = try JSONDecoder().decode(SaveData.self, from: Data(#"{"a":true,"b":1}"#.utf8))
        XCTAssertEqual(decoded["a"], .bool(true))
        XCTAssertEqual(decoded["b"], .number(1))
    }

    func testLimitsRefuseRatherThanTruncateStructure() {
        var data = SaveData()
        XCTAssertFalse(data.set(String(repeating: "k", count: SaveData.Limits.maximumKeyLength + 1), .number(1)))
        XCTAssertFalse(data.set("nan", .number(.nan)))
        XCTAssertFalse(data.set("huge", .list(Array(repeating: .string(String(repeating: "x", count: 1_000)), count: 100))))
        var deep: SaveValue = .number(1)
        for _ in 0..<SaveData.Limits.maximumDepth { deep = .list([deep]) }
        XCTAssertFalse(data.set("deep", deep))
        XCTAssertTrue(data.isEmpty)

        // Long text is cut, not refused.
        XCTAssertTrue(data.set("note", .string(String(repeating: "あ", count: 5_000))))
        guard case let .string(note)? = data["note"] else { return XCTFail("note missing") }
        XCTAssertEqual(note.count, SaveData.Limits.maximumStringLength)

        XCTAssertTrue(data.set("note", nil))
        XCTAssertNil(data["note"])
    }

    func testAHandEditedFileIsHeldToTheSameLimits() throws {
        let json = #"{"ok":1,"bad":{"\#(String(repeating: "k", count: 100))":1}}"#
        let decoded = try JSONDecoder().decode(SaveData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded["ok"], .number(1))
        XCTAssertNil(decoded["bad"])
    }

    // MARK: Files

    private func temporaryStore() -> GameSaveStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("saves-\(UUID().uuidString)")
        return GameSaveStore(directory: directory)
    }

    func testTheStoreRoundTripsAndLists() throws {
        let store = temporaryStore()
        let world = UUID()
        try store.save(SaveData(["coins": .number(5)]), worldID: world, worldName: "Rhythm Battle")
        XCTAssertEqual(store.load(worldID: world)?["coins"], .number(5))
        XCTAssertEqual(store.summaries().map(\.worldName), ["Rhythm Battle"])
        store.delete(worldID: world)
        XCTAssertNil(store.load(worldID: world))
        XCTAssertTrue(store.summaries().isEmpty)
    }

    func testABrokenFileFallsBackToThePreviousSave() throws {
        let store = temporaryStore()
        let world = UUID()
        try store.save(SaveData(["coins": .number(1)]), worldID: world, worldName: "A")
        try store.save(SaveData(["coins": .number(2)]), worldID: world, worldName: "A")
        let file = store.directory.appendingPathComponent(world.uuidString).appendingPathExtension("save")
        try Data("{ not json".utf8).write(to: file)
        XCTAssertEqual(store.load(worldID: world)?["coins"], .number(1))
    }

    func testMergingKeepsTheNewerCopy() throws {
        let store = temporaryStore()
        let world = UUID()
        let now = Date()
        try store.save(SaveData(["coins": .number(10)]), worldID: world, worldName: "A", at: now)
        let older = GameSaveStore.Record(worldID: world, worldName: "A", savedAt: now.addingTimeInterval(-60), data: SaveData(["coins": .number(1)]))
        let other = GameSaveStore.Record(worldID: UUID(), worldName: "B", savedAt: now, data: SaveData(["gems": .number(3)]))
        XCTAssertEqual(store.merge([older, other]), 1)
        XCTAssertEqual(store.load(worldID: world)?["coins"], .number(10))
        XCTAssertEqual(store.load(worldID: other.worldID)?["gems"], .number(3))
    }

    // MARK: Backup file

    func testABackupRoundTripsAndRefusesWhatIsNotOne() throws {
        var wallet = PlayerWallet()
        wallet.earn(300)
        let record = GameSaveStore.Record(worldID: UUID(), worldName: "Shark Attack Bay", savedAt: Date(timeIntervalSince1970: 1_000),
                                          data: SaveData(["harpoon": .bool(true)]))
        let backup = AbloxBackup(profile: .default, wallet: wallet, saves: [record], worlds: [WorldDocument(name: "Mine")])
        let read = try AbloxBackup.decoded(from: try backup.encoded())
        XCTAssertEqual(read.wallet.coins, 300)
        XCTAssertEqual(read.saves.first?.data["harpoon"], .bool(true))
        XCTAssertEqual(read.worlds.first?.name, "Mine")

        XCTAssertThrowsError(try AbloxBackup.decoded(from: Data("hello".utf8))) {
            XCTAssertEqual($0 as? AbloxBackup.ReadError, .notABackup)
        }
        var future = backup
        future.version = AbloxBackup.currentVersion + 1
        XCTAssertThrowsError(try AbloxBackup.decoded(from: try future.encoded())) {
            XCTAssertEqual($0 as? AbloxBackup.ReadError, .newerVersion)
        }
        XCTAssertTrue(AbloxBackup.suggestedFileName(on: Date(timeIntervalSince1970: 0)).hasSuffix(".abloxbackup"))
    }

    func testRestoringAWalletNeverLowersItOrDoublesIt() {
        var here = PlayerWallet()
        here.earn(500)
        var backup = PlayerWallet()
        backup.earn(200)
        _ = backup.purchase("hat.crown")
        let merged = here.merged(with: backup).merged(with: backup)
        XCTAssertEqual(merged.coins, 500)
        XCTAssertTrue(merged.owns("hat.crown"))
    }

    // MARK: Scripts

    private let saver = #"""
    on join(p)
      p.coins = 0
      print("join saved=" + (p.saved == nil) + " early=" + p.save("coins", 1))
    end

    on loaded(p)
      let s = p.saved
      if s.coins != nil then p.coins = s.coins end
      print("loaded coins=" + p.coins)
    end

    on button(p, id)
      if id == "earn" then
        p.coins = p.coins + 10
        p.save("coins", p.coins)
        p.save("pets", ["cat", "dog"])
      elif id == "same" then
        p.save("coins", p.coins)
      elif id == "forget" then
        p.save("pets")
      elif id == "bad" then
        p.save("oops", func() end)
      end
    end
    """#

    private func stored(_ peer: PeerID, _ effects: [GameRuntime.Effect]) -> [SaveData] {
        scripted(peer, effects).compactMap { if case let .store(data) = $0 { return data }; return nil }
    }

    private func pressed(_ game: GameRuntime, _ id: String, _ peer: PeerID, at time: Double) -> [GameRuntime.Effect] {
        // A button the script never showed would be refused, so show it first.
        game.handle(.button(id: id), from: peer, at: time)
    }

    func testSavingWaitsForTheDataThenGoesBackBatched() {
        let game = game(saver + "\n" + #"""
        on start()
          ui_button("earn", "Earn")
          ui_button("same", "Same")
          ui_button("forget", "Forget")
          ui_button("bad", "Bad")
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        XCTAssertEqual(game.drainOutput(), ["join saved=true early=false", "join saved=true early=false"])

        game.handle(.saved(SaveData(["coins": .number(40)])), from: alice, at: 1)
        XCTAssertEqual(game.drainOutput(), ["loaded coins=40"])

        // A second copy (a reconnect) must not roll back this session.
        _ = pressed(game, "earn", alice, at: 1.2)
        game.handle(.saved(SaveData(["coins": .number(0)])), from: alice, at: 1.3)
        XCTAssertEqual(game.drainOutput(), [])

        let first = game.advance(to: 1.5)
        XCTAssertTrue(stored(bob, first).isEmpty, "Bob's data never arrived, so nothing of his is written")
        var sent = stored(alice, first)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["coins"], .number(50))
        XCTAssertEqual(sent.first?["pets"], .list([.string("cat"), .string("dog")]))

        // Unchanged: nothing to send.
        _ = pressed(game, "same", alice, at: 1.55)
        XCTAssertTrue(stored(alice, game.advance(to: 1.6)).isEmpty)

        // Forgetting a key is a change; within a second of the last copy it waits.
        _ = pressed(game, "forget", alice, at: 1.7)
        XCTAssertTrue(stored(alice, game.advance(to: 1.9)).isEmpty)
        sent = stored(alice, game.advance(to: 2.6))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["pets"], nil)
        XCTAssertEqual(sent.first?["coins"], .number(50))

        _ = pressed(game, "bad", alice, at: 5)
        XCTAssertTrue(game.drainErrors().contains { $0.message.contains("function") })
    }

    func testARestartedRoundReadsTheSaveAgain() {
        let game = game(saver)
        startWithBoth(game)
        game.handle(.saved(SaveData(["coins": .number(7)])), from: bob, at: 1)
        _ = game.drainOutput()
        game.handle(.roundStarted)
        // The save is already here when the new round's `on join` runs, so
        // saving there works at once, and `on loaded` follows.
        XCTAssertEqual(game.drainOutput(), ["join saved=true early=false", "join saved=false early=true", "loaded coins=1"])
    }

    func testAPlayersValuesCanBeReachedByName() {
        let game = game(#"""
        on join(p)
          let key = "coins"
          p[key] = 12
          p["hat"] = "crown"
          print(p.coins + " " + p[key] + " " + p["hat"] + " " + p.hat)
        end
        """#)
        game.addPlayer(snapshot(alice, "Alice"))
        game.handle(.roundStarted)
        XCTAssertEqual(game.drainErrors().map(\.message), [])
        XCTAssertEqual(game.drainOutput(), ["12 12 crown crown"])
    }

    func testNPCsHaveNothingToSave() {
        let game = game(#"""
        on start()
          let n = create_npc({name: "Bot"})
          print("npc saved=" + (n.saved == nil) + " save=" + n.save("x", 1))
        end
        """#)
        startWithBoth(game)
        XCTAssertEqual(game.drainOutput(), ["npc saved=true save=false"])
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
