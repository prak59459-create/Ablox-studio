import XCTest
@testable import AbloxCore

final class PlayerProgressTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func day(_ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    // MARK: Daily bonus

    func testDailyBonusGrowsWithTheStreakAndOnlyOncePerDay() {
        var bonus = DailyBonus()
        XCTAssertTrue(bonus.isWaiting(on: day(1), calendar: calendar))
        XCTAssertEqual(bonus.claim(on: day(1), calendar: calendar), DailyBonus.base)
        XCTAssertNil(bonus.claim(on: day(1, hour: 22), calendar: calendar), "one bonus a day")
        XCTAssertFalse(bonus.isWaiting(on: day(1, hour: 23), calendar: calendar))
        XCTAssertEqual(bonus.claim(on: day(2), calendar: calendar), DailyBonus.base + DailyBonus.perDay)
        XCTAssertEqual(bonus.claim(on: day(3), calendar: calendar), DailyBonus.base + 2 * DailyBonus.perDay)
        XCTAssertEqual(bonus.streak, 3)
    }

    func testMissingADayStartsTheStreakAgain() {
        var bonus = DailyBonus()
        _ = bonus.claim(on: day(1), calendar: calendar)
        _ = bonus.claim(on: day(2), calendar: calendar)
        XCTAssertEqual(bonus.claim(on: day(4), calendar: calendar), DailyBonus.base)
        XCTAssertEqual(bonus.streak, 1)
    }

    func testDailyBonusStopsGrowingAtTheCap() {
        var bonus = DailyBonus()
        var last = 0
        for d in 1...20 { last = bonus.claim(on: day(d), calendar: calendar) ?? 0 }
        XCTAssertEqual(last, DailyBonus.maximum)
    }

    func testDailyBonusSurvivesSaving() throws {
        var bonus = DailyBonus()
        _ = bonus.claim(on: day(5), calendar: calendar)
        let back = try JSONDecoder().decode(DailyBonus.self, from: JSONEncoder().encode(bonus))
        XCTAssertEqual(back, bonus)
        var again = back
        XCTAssertNil(again.claim(on: day(5, hour: 20), calendar: calendar))
    }

    // MARK: Badges

    func testNothingIsEarnedAtTheStart() {
        XCTAssertTrue(Achievement.earned(ProgressStats()).isEmpty)
    }

    func testBadgesFollowWhatWasDone() {
        let stats = ProgressStats(gamesPlayed: 12, totalMinutes: 90, daysPlayed: 3, lifetimeCoins: 600,
                                  itemsOwned: 16, pictures: 2, worldsMade: 1, hasPet: true, bestStreak: 2)
        let earned = Set(Achievement.earned(stats))
        XCTAssertEqual(earned, [.firstGame, .explorer, .playtime, .saver, .stylist, .builder, .petFriend])
        XCTAssertFalse(earned.contains(.globetrotter))
        XCTAssertFalse(earned.contains(.loyal))
    }

    func testEveryBadgeHasWordsAndAPicture() {
        for badge in Achievement.allCases {
            XCTAssertFalse(badge.title.isEmpty)
            XCTAssertFalse(badge.detail.isEmpty)
            XCTAssertFalse(badge.symbolName.isEmpty)
        }
        let titles = Achievement.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "a title names one badge")
    }

    // MARK: Rarity

    func testRarityFollowsPrice() {
        XCTAssertEqual(ItemRarity(price: 0), .common)
        XCTAssertEqual(ItemRarity(price: 99), .common)
        XCTAssertEqual(ItemRarity(price: 100), .rare)
        XCTAssertEqual(ItemRarity(price: 300), .epic)
        XCTAssertEqual(ItemRarity(price: 600), .legendary)
        XCTAssertLessThan(ItemRarity.rare, .legendary)
        XCTAssertTrue(ShopCatalogue.items.contains { $0.rarity == .legendary }, "something to save up for")
    }

    func testFacesAndPetsAreInTheShopWithAFreeChoice() {
        let wallet = PlayerWallet()
        XCTAssertEqual(ShopCatalogue.items(of: .face).count, AvatarProfile.Face.allCases.count)
        XCTAssertEqual(ShopCatalogue.items(of: .pet).count, AvatarProfile.Pet.allCases.count)
        XCTAssertTrue(wallet.ownedItems(of: .face).contains { $0.face == .smile })
        XCTAssertTrue(wallet.ownedItems(of: .pet).contains { $0.pet == AvatarProfile.Pet.none })
        XCTAssertFalse(wallet.lockedItems(of: .pet).isEmpty)
    }

    // MARK: Avatar

    func testNewLookSurvivesSavingAndAnOldProfileStillLoads() throws {
        var profile = AvatarProfile(displayName: "Mika")
        profile.face = .cat
        profile.pet = .dragon
        profile.hatColor = ColorRGBA(r: 1, g: 0, b: 0)
        profile.title = "Adventurer"
        let back = try JSONDecoder().decode(AvatarProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(back.face, .cat)
        XCTAssertEqual(back.pet, .dragon)
        XCTAssertEqual(back.hatColor, profile.hatColor)
        XCTAssertEqual(back.title, "Adventurer")

        let plain = String(decoding: try JSONEncoder().encode(AvatarProfile(displayName: "Mika")), as: UTF8.self)
        XCTAssertFalse(plain.contains("face"), "defaults are left out for older iPads")
        XCTAssertFalse(plain.contains("pet"))

        let old = #"{"displayName":"Old","bodyColor":{"r":1,"g":1,"b":1,"a":1},"headColor":{"r":1,"g":1,"b":1,"a":1},"accentColor":{"r":1,"g":1,"b":1,"a":1},"hat":"none","height":1}"#
        let loaded = try JSONDecoder().decode(AvatarProfile.self, from: Data(old.utf8))
        XCTAssertEqual(loaded.face, .smile)
        XCTAssertEqual(loaded.pet, AvatarProfile.Pet.none)
        XCTAssertNil(loaded.hatColor)
    }

    func testAFaceFromANewerIPadFallsBackToASmile() throws {
        let newer = #"{"displayName":"New","bodyColor":{"r":1,"g":1,"b":1,"a":1},"headColor":{"r":1,"g":1,"b":1,"a":1},"accentColor":{"r":1,"g":1,"b":1,"a":1},"hat":"none","height":1,"face":"alien","pet":"unicorn"}"#
        let loaded = try JSONDecoder().decode(AvatarProfile.self, from: Data(newer.utf8))
        XCTAssertEqual(loaded.face, .smile)
        XCTAssertEqual(loaded.pet, AvatarProfile.Pet.none)
    }

    // MARK: Catalogue shelves

    private func listing(_ id: String, tags: [String] = [], maxPlayers: Int = 4, cover: String? = nil) -> GameListing {
        GameListing(id: id, title: id.capitalized, world: "games/\(id)/world.ablox", cover: cover, tags: tags,
                    blockCount: 10, maxPlayers: maxPlayers)
    }

    func testTodaysPickIsTheSameAllDayAndChanges() {
        let games = (1...30).map { listing("game-\($0)") }
        let morning = CatalogueShelf.dailyPick(from: games, on: day(3, hour: 8), calendar: calendar)
        let evening = CatalogueShelf.dailyPick(from: games.reversed(), on: day(3, hour: 21), calendar: calendar)
        XCTAssertEqual(morning?.id, evening?.id, "order of the list does not matter")
        let week = Set((1...7).compactMap { CatalogueShelf.dailyPick(from: games, on: day($0), calendar: calendar)?.id })
        XCTAssertGreaterThan(week.count, 1)
        XCTAssertNil(CatalogueShelf.dailyPick(from: [], calendar: calendar))
    }

    func testNewAndUpdatedMarks() {
        let game = listing("sky", cover: "games/sky/cover-1.png")
        XCTAssertEqual(CatalogueShelf.freshness(of: game, seen: [:]), .new)
        XCTAssertEqual(CatalogueShelf.freshness(of: game, seen: ["sky": game.revisionKey]), .seen)
        var changed = game
        changed.cover = "games/sky/cover-2.png"
        XCTAssertEqual(CatalogueShelf.freshness(of: changed, seen: ["sky": game.revisionKey]), .updated)
    }

    func testTraitsComeFromTags() {
        let scary = CatalogueShelf.traits(of: listing("a", tags: ["Horror", "coop"]))
        XCTAssertTrue(scary.scary)
        XCTAssertTrue(scary.social)
        XCTAssertFalse(scary.gentle)
        let gentle = CatalogueShelf.traits(of: listing("b", tags: ["pets", "speedrun"]))
        XCTAssertTrue(gentle.gentle)
        XCTAssertTrue(gentle.hard)
        XCTAssertFalse(gentle.scary)
    }

    func testPlayerCountFilter() {
        let solo = listing("solo", maxPlayers: 1)
        let big = listing("big", maxPlayers: 8)
        XCTAssertTrue(CatalogueShelf.PlayerCount.solo.allows(solo))
        XCTAssertFalse(CatalogueShelf.PlayerCount.few.allows(solo))
        XCTAssertTrue(CatalogueShelf.PlayerCount.many.allows(big))
        XCTAssertFalse(CatalogueShelf.PlayerCount.many.allows(listing("mid", maxPlayers: 4)))
        XCTAssertTrue(CatalogueShelf.PlayerCount.any.allows(solo))
    }

    func testCommonTagsAreTheMostSharedWithoutTheInternalOne() {
        let games = [listing("a", tags: ["obby", "top20"]), listing("b", tags: ["obby", "pvp"]), listing("c", tags: ["pvp", "obby"])]
        XCTAssertEqual(CatalogueShelf.commonTags(in: games, limit: 2), ["obby", "pvp"])
        XCTAssertFalse(CatalogueShelf.commonTags(in: games).contains("top20"))
    }

    func testQuestsAndInstructionsAreReadFromScripts() {
        let script = """
        kit_setup("Sky Temple", "Climb to the top", ["Jump on the clouds", "Find the \\"gold\\" bell", "Don't fall"])
        kit_quest("bells", "Ring 3 bells", 3, 50)
        kit_quest( "top" , "Reach the top", 1 , 120 )
        """
        XCTAssertEqual(CatalogueShelf.instructions(inScripts: ["print(1)", script]),
                       ["Jump on the clouds", "Find the \"gold\" bell", "Don't fall"])
        let quests = CatalogueShelf.quests(inScripts: [script])
        XCTAssertEqual(quests.map(\.title), ["Ring 3 bells", "Reach the top"])
        XCTAssertEqual(quests.map(\.reward), [50, 120])
        XCTAssertTrue(CatalogueShelf.instructions(inScripts: ["let x = 1"]).isEmpty)
    }

    // MARK: Pictures on a game's page

    func testShotsAreCheckedLikeCovers() {
        var game = listing("sky", cover: "games/sky/cover.png")
        game.shots = ["games/sky/shot-1.png", "games/sky/shot-2.jpg"]
        XCTAssertNil(game.rejection())
        XCTAssertEqual(CatalogueSource(repository: "someone/ablox-games").shotURLs(for: game).count, 2)

        game.shots = ["../../secret.png"]
        XCTAssertEqual(game.rejection(), .invalidPath(field: "shots", value: "../../secret.png"))
        game.shots = (1...5).map { "games/sky/shot-\($0).png" }
        XCTAssertEqual(game.rejection(), .fieldTooLong(field: "shots", limit: GameCatalogue.Limits.maximumShots))
    }

    // MARK: Save slots

    func testSlotOneIsTheWorldAndOtherSlotsAreDistinct() {
        let world = UUID()
        XCTAssertEqual(SaveSlots.storageID(world: world, slot: 1), world, "saves from before slots are slot 1")
        let ids = (1...SaveSlots.count).map { SaveSlots.storageID(world: world, slot: $0) }
        XCTAssertEqual(Set(ids).count, SaveSlots.count)
        XCTAssertEqual(SaveSlots.storageID(world: world, slot: 2), SaveSlots.storageID(world: world, slot: 2), "stable")
    }
}
