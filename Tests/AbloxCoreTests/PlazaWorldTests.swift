import XCTest
@testable import AbloxCore

/// The Plaza: a door for every game asked for and the menu's two, each one
/// walked into rather than bumped against, and a world that plays as it is.
final class PlazaWorldTests: XCTestCase {

    private func game(_ id: String, tags: [String] = []) -> GameListing {
        GameListing(id: id, title: "Game \(id)", author: "", world: "games/\(id)/world.ablox", tags: tags, blockCount: 100,
                    maxPlayers: 8, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testADoorForEveryGameAndTheMenusTwo() {
        let games = (1...6).map { game("g\($0)") }
        let plaza = PlazaWorld.build(games: games, playerName: "Sam")
        XCTAssertEqual(plaza.doors.count, games.count + 2)
        XCTAssertEqual(Set(plaza.doors.values), Set(games.map { PlazaWorld.Door.game($0.id) } + [.closet, .allGames]))
        for id in plaza.doors.keys {
            let block = plaza.world.blocks.first { $0.id == id }
            XCTAssertEqual(block?.behavior, .trigger, "a door is walked into, not bumped against")
            XCTAssertNotNil(block?.label)
        }
    }

    func testThePlazaHasOneStartAndNoTwoPartsAlike() {
        let plaza = PlazaWorld.build(games: (1...8).map { game("g\($0)") }, playerName: "Sam")
        let blocks = plaza.world.blocks
        XCTAssertEqual(blocks.filter { $0.behavior == .spawn }.count, 1)
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
        XCTAssertEqual(plaza.world.id, PlazaWorld.worldID)
        XCTAssertFalse(plaza.world.scripts.isEmpty)
    }

    private let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])

    func testACoverGoesOnItsDoor() {
        let games = [game("a"), game("b"), game("c")]
        let plaza = PlazaWorld.build(games: games, covers: ["b": picture, "c": Data("not a picture".utf8)], playerName: "Sam")
        XCTAssertEqual(plaza.world.images.count, 1)
        let doorB = plaza.doors.first { $0.value == .game("b") }?.key
        let block = plaza.world.blocks.first { $0.id == doorB }
        XCTAssertEqual(block?.imageID, plaza.world.images.first?.id)
        let doorA = plaza.doors.first { $0.value == .game("a") }?.key
        XCTAssertNil(plaza.world.blocks.first { $0.id == doorA }?.imageID)
        let doorC = plaza.doors.first { $0.value == .game("c") }?.key
        XCTAssertNil(plaza.world.blocks.first { $0.id == doorC }?.imageID, "what is not a picture stays off the door")
        XCTAssertTrue(plaza.world.images.allSatisfy(\.isAcceptable))
    }

    func testTheDoorsGoToTodaysPickTheRecentThenThePopular() {
        let listings = (1...20).map { game("g\($0)", tags: $0 == 15 ? ["top20"] : []) }
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let picked = PlazaWorld.games(from: listings, recent: ["g3", "g3", "missing", "g7"], count: 5, on: date)
        XCTAssertEqual(picked.count, 5)
        XCTAssertEqual(Set(picked.map(\.id)).count, 5, "no game twice")
        XCTAssertEqual(picked.first?.id, CatalogueShelf.dailyPick(from: listings, on: date)?.id)
        XCTAssertTrue(picked.contains { $0.id == "g3" })
        XCTAssertTrue(picked.contains { $0.id == "g7" })
        XCTAssertTrue(picked.contains { $0.id == "g15" })
        XCTAssertTrue(PlazaWorld.games(from: [], recent: ["g1"]).isEmpty)
    }

    func testThePlazaSurvivesBeingSavedAndOpened() throws {
        let plaza = PlazaWorld.build(games: [game("a")], covers: ["a": picture], playerName: "Sam \"the\" builder")
        let data = try JSONEncoder().encode(plaza.world)
        let back = try JSONDecoder().decode(WorldDocument.self, from: data)
        XCTAssertEqual(back.blocks.count, plaza.world.blocks.count)
        XCTAssertEqual(back.images.count, 1)
    }

    func testTheHelloScriptRuns() throws {
        let plaza = PlazaWorld.build(games: [game("a")], playerName: "Sam")
        for script in plaza.world.scripts {
            XCTAssertNoThrow(try ScriptParser.parse(script.source), script.source)
        }
    }
}
