import XCTest
@testable import AbloxCore

final class BrowsingOutfitRepairTests: XCTestCase {

    private func listing(_ id: String, _ title: String, days: Double = 0) -> GameListing {
        GameListing(id: id, title: title, world: "games/\(id)/world.ablox",
                    updatedAt: Date(timeIntervalSince1970: 1_000_000 + days * 86_400))
    }

    // MARK: Sorting, hiding, searching

    func testSortOrders() {
        let games = [listing("b", "Bravo", days: 1), listing("a", "alpha", days: 3), listing("c", "Charlie", days: 2)]
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .suggested).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .name).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .newest).map(\.id), ["a", "c", "b"])
        let played: [String: Double] = ["c": 500, "b": 20]
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .mostPlayed, playedSeconds: { played[$0.id] ?? 0 }).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .liked, liked: ["c"]).map(\.id), ["c", "b", "a"], "ties keep the list's order")
    }

    func testHiddenGamesAreLeftOut() {
        let games = [listing("a", "A"), listing("b", "B")]
        XCTAssertEqual(CatalogueBrowsing.visible(games, hidden: ["a"]).map(\.id), ["b"])
        XCTAssertEqual(CatalogueBrowsing.visible(games, hidden: []).count, 2)
    }

    func testSurprisePrefersUnplayedGames() {
        let games = [listing("a", "A"), listing("b", "B"), listing("c", "C")]
        for seed in 0..<50 as Range<UInt64> {
            let pick = CatalogueBrowsing.surprise(from: games, played: ["a", "b"], seed: seed)
            XCTAssertEqual(pick?.id, "c")
        }
        let everything = Set((0..<200 as Range<UInt64>).compactMap { CatalogueBrowsing.surprise(from: games, played: ["a", "b", "c"], seed: $0)?.id })
        XCTAssertEqual(everything, ["a", "b", "c"], "all played: any of them, and all get picked")
        XCTAssertNil(CatalogueBrowsing.surprise(from: [], played: [], seed: 1))
    }

    func testRecentSearches() {
        var searches = RecentSearches()
        searches.add("  obby ")
        searches.add("x")
        searches.add("Tycoon")
        searches.add("OBBY")
        XCTAssertEqual(searches.items, ["OBBY", "Tycoon"])
        for index in 0..<20 { searches.add("game \(index)") }
        XCTAssertEqual(searches.items.count, RecentSearches.kept)
        XCTAssertEqual(searches.items.first, "game 19")
        searches.remove("game 19")
        XCTAssertEqual(searches.items.first, "game 18")
        searches.clear()
        XCTAssertTrue(searches.items.isEmpty)
    }

    // MARK: Outfit codes

    func testOutfitCodeRoundTrip() throws {
        let palette = ColorRGBA.palette
        let profile = AvatarProfile(displayName: "Secret name", bodyColor: palette[5], headColor: palette[2], accentColor: palette[7],
                                    hat: .crown, height: 1.1, face: .cool, hatColor: palette[1], pet: .dragon, petColor: palette[9])
        let code = OutfitCode.code(for: profile)
        XCTAssertFalse(code.contains("Secret"), "never the name")
        XCTAssertLessThanOrEqual(code.count, 24)
        let outfit = try XCTUnwrap(OutfitCode.outfit(from: code))
        XCTAssertEqual(outfit.body, palette[5])
        XCTAssertEqual(outfit.head, palette[2])
        XCTAssertEqual(outfit.accent, palette[7])
        XCTAssertEqual(outfit.hat, .crown)
        XCTAssertEqual(outfit.face, .cool)
        XCTAssertEqual(outfit.pet, .dragon)
        XCTAssertEqual(outfit.hatColor, palette[1])
        XCTAssertEqual(outfit.petColor, palette[9])
        XCTAssertEqual(outfit.height, 1.1, accuracy: 0.01)
        // Typed in lower case, without dashes, with O for 0: still read.
        let typed = code.replacingOccurrences(of: "-", with: " ").lowercased().replacingOccurrences(of: "0", with: "o")
        XCTAssertEqual(OutfitCode.outfit(from: typed), outfit)
    }

    func testAMistypedCodeIsRefused() {
        let code = OutfitCode.code(for: AvatarProfile())
        var characters = Array(code)
        let spot = characters.firstIndex { $0 != "-" }!
        characters[spot] = characters[spot] == "7" ? "8" : "7"
        XCTAssertNil(OutfitCode.outfit(from: String(characters)))
        XCTAssertNil(OutfitCode.outfit(from: ""))
        XCTAssertNil(OutfitCode.outfit(from: "hello world"))
    }

    func testWearingPutsOnOnlyWhatIsOwned() throws {
        let palette = ColorRGBA.palette
        let wanted = AvatarProfile(bodyColor: palette[0], headColor: palette[9], hat: .crown, pet: .dragon, petColor: palette[3])
        let outfit = try XCTUnwrap(OutfitCode.outfit(from: OutfitCode.code(for: wanted)))
        let mine = AvatarProfile(displayName: "Me", headColor: palette[1])
        let result = OutfitCode.wear(outfit, on: mine, wallet: PlayerWallet())
        XCTAssertEqual(result.profile.displayName, "Me")
        XCTAssertEqual(result.profile.bodyColor, palette[0], "a free colour")
        XCTAssertEqual(result.profile.headColor, palette[1], "not owned: kept")
        XCTAssertEqual(result.profile.hat, mine.hat)
        XCTAssertEqual(result.profile.petColor, palette[3], "free to choose")
        let missing = Set(result.missing.map(\.id))
        XCTAssertTrue(missing.contains("hat.crown"))
        XCTAssertTrue(missing.contains("pet.dragon"))
        XCTAssertTrue(missing.contains { $0.hasPrefix("headColor.") })

        var wallet = PlayerWallet(coins: 5_000)
        for item in result.missing { _ = wallet.purchase(item.id) }
        let again = OutfitCode.wear(outfit, on: mine, wallet: wallet)
        XCTAssertTrue(again.missing.isEmpty)
        XCTAssertEqual(again.profile.hat, .crown)
        XCTAssertEqual(again.profile.pet, .dragon)
    }

    // MARK: Mending worlds

    private func block(_ name: String, id: UUID = UUID(), parent: UUID? = nil) -> BlockData {
        var block = BlockData(name: name, shape: .box, transform: Transform3D(position: Vec3(1, 2, 3)),
                              color: ColorRGBA(r: 0.5, g: 0.5, b: 0.5), material: .plastic)
        block.id = id
        block.parentID = parent
        return block
    }

    func testAHealthyWorldIsUntouched() {
        let parent = block("Parent")
        let world = WorldDocument(blocks: [parent, block("Child", parent: parent.id)])
        let result = WorldRepair.repaired(world)
        XCTAssertTrue(result.report.isEmpty)
        XCTAssertEqual(result.world, world)
    }

    func testBadNumbersSizesAndColoursAreMended() {
        var broken = block("Broken")
        broken.transform.position = Vec3(.nan, 1, .infinity)
        broken.transform.rotation = Quat(x: 0, y: 0, z: 0, w: 0)
        broken.transform.scale = Vec3(0, -3, 99_999)
        broken.color = ColorRGBA(r: 2, g: -1, b: .nan, a: .nan)
        let result = WorldRepair.repaired(WorldDocument(blocks: [broken]))
        let mended = result.world.blocks[0]
        XCTAssertEqual(mended.transform.position, .zero)
        XCTAssertEqual(mended.transform.rotation, .identity)
        XCTAssertEqual(mended.transform.scale, Vec3(WorldRepair.smallestSize, 3, WorldRepair.largestSize))
        XCTAssertEqual(mended.color, ColorRGBA(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(result.report.badNumbers, 2)
        XCTAssertEqual(result.report.badSizes, 1)
        XCTAssertEqual(result.report.badColours, 1)
        XCTAssertFalse(result.report.summary.isEmpty)
    }

    func testSharedIDsAndBrokenGroupsAreMended() {
        let shared = UUID()
        let a = block("A", id: shared)
        let b = block("B", id: shared)
        let orphan = block("Orphan", parent: UUID())
        let loopA = UUID(), loopB = UUID()
        let x = block("X", id: loopA, parent: loopB)
        let y = block("Y", id: loopB, parent: loopA)
        let result = WorldRepair.repaired(WorldDocument(blocks: [a, b, orphan, x, y]))
        let ids = result.world.blocks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(result.world.blocks[0].id, shared, "the first keeps its id")
        XCTAssertNil(result.world.blocks[2].parentID)
        // One link of the loop is cut; the other part stays in the group.
        XCTAssertEqual(result.world.blocks[3...4].filter { $0.parentID == nil }.count, 1)
        XCTAssertEqual(result.report.duplicateIDs, 1)
        XCTAssertEqual(result.report.brokenParents, 2)
    }

    func testEveryWorldReadIsMended() throws {
        var broken = block("Broken")
        broken.transform.scale = Vec3(0, 1, 1)
        let data = try WorldDocument(blocks: [broken]).encodedForFile()
        let read = try WorldDocument.decodedAndRepaired(from: data)
        XCTAssertEqual(read.world.blocks[0].scale.x, WorldRepair.smallestSize)
        XCTAssertEqual(read.repairs.badSizes, 1)
        XCTAssertEqual(try WorldDocument.decoded(from: data).blocks[0].scale.x, WorldRepair.smallestSize)
    }

    func testTheTemplatesNeedNoMending() {
        for template in [WorldDocument.starter()] {
            XCTAssertTrue(WorldRepair.repaired(template).report.isEmpty)
        }
    }
}
