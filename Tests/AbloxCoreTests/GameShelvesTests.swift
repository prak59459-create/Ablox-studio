import XCTest
@testable import AbloxCore

/// The Games tab, the second round.
final class GameShelvesTests: XCTestCase {

    private func game(_ id: String, _ title: String, author: String = "", tags: [String] = [], parts: Int = 100,
                      players: Int = 4, days: Double = 0) -> GameListing {
        GameListing(id: id, title: title, author: author, world: "games/\(id)/world.ablox", tags: tags, blockCount: parts,
                    maxPlayers: players, updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + days * 86_400))
    }

    func testSearchFoldsCaseWidthAndKana() {
        XCTAssertEqual(SearchText.fold("ＧＡＭＥ"), "game")
        XCTAssertEqual(SearchText.fold("ﾚｰｽ"), "レース")
        XCTAssertEqual(SearchText.fold("れーす"), "レース")
        XCTAssertTrue(SearchText.matches("れーす たわー", in: ["Tower Race", "タワーでレース"]))
        XCTAssertTrue(SearchText.matches("tower", in: ["Tower Race"]))
        XCTAssertFalse(SearchText.matches("tower boat", in: ["Tower Race"]))
        XCTAssertTrue(SearchText.matches("  ", in: ["Anything"]))
    }

    func testSuggestionsAndDidYouMean() {
        let titles = ["Obby Tower", "Obstacle Run", "Pet Cafe", "Robot Obby"]
        XCTAssertEqual(SearchText.suggestions(for: "ob", in: titles), ["Obby Tower", "Obstacle Run", "Robot Obby"])
        XCTAssertEqual(SearchText.suggestions(for: "", in: titles), [])
        XCTAssertEqual(SearchText.closest(to: "pet cafo", in: titles), "Pet Cafe")
        XCTAssertEqual(SearchText.closest(to: "robbot", in: titles), "Robot Obby")
        XCTAssertNil(SearchText.closest(to: "zzzzzz", in: titles))
        XCTAssertNil(SearchText.closest(to: "ab", in: titles), "too short to guess")
    }

    func testNewSortsKeepTiesInOrder() {
        let games = [game("a", "A", parts: 300, players: 2), game("b", "B", parts: 50, players: 8), game("c", "C", parts: 50, players: 2)]
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .smallest).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .players).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(CatalogueBrowsing.sorted(games, by: .rating, stars: ["c": 5, "a": 3]).map(\.id), ["c", "a", "b"])
    }

    func testFilters() {
        let gentle = game("g", "Garden", tags: ["cute"])
        let hard = game("h", "Hard", tags: ["speedrun"])
        let context = GameFilter.Context(downloaded: ["g"], played: ["h"], favourites: ["h"], playLater: ["g"])
        XCTAssertTrue(GameFilter.downloaded.allows(gentle, context))
        XCTAssertFalse(GameFilter.downloaded.allows(hard, context))
        XCTAssertTrue(GameFilter.notPlayed.allows(gentle, context))
        XCTAssertFalse(GameFilter.notPlayed.allows(hard, context))
        XCTAssertTrue(GameFilter.favourites.allows(hard, context))
        XCTAssertTrue(GameFilter.playLater.allows(gentle, context))
        XCTAssertTrue(GameFilter.gentle.allows(gentle, context))
        XCTAssertFalse(GameFilter.notHard.allows(hard, context))
    }

    func testCollectionsAndRatings() throws {
        var lists = GameCollections()
        XCTAssertNil(lists.create("   "))
        let racing = try XCTUnwrap(lists.create("Racing"))
        XCTAssertTrue(lists.toggle("kart", in: racing))
        XCTAssertTrue(lists.contains("kart", in: racing))
        XCTAssertFalse(lists.toggle("kart", in: racing), "twice takes it out")
        lists.toggle("kart", in: racing)
        lists.rename(racing, to: "Fast games")
        XCTAssertEqual(lists.all.first?.name, "Fast games")
        lists.forget("kart")
        XCTAssertFalse(lists.contains("kart", in: racing))
        for n in 1..<GameCollections.maximumCollections { lists.create("List \(n)") }
        XCTAssertNil(lists.create("One too many"))
        let back = try JSONDecoder().decode(GameCollections.self, from: JSONEncoder().encode(lists))
        XCTAssertEqual(back, lists)
        lists.delete(racing)
        XCTAssertEqual(lists.all.count, GameCollections.maximumCollections - 1)

        var ratings = GameRatings()
        ratings.rate("kart", 4)
        XCTAssertEqual(ratings.stars(for: "kart"), 4)
        ratings.rate("kart", 4)
        XCTAssertEqual(ratings.stars(for: "kart"), 0, "the same stars again clears them")
        ratings.rate("kart", 9)
        XCTAssertEqual(ratings.stars(for: "kart"), 5)
        let odd = try JSONDecoder().decode(GameRatings.self, from: Data(#"{"a":3,"b":0,"c":12}"#.utf8))
        XCTAssertEqual(odd.stars, ["a": 3])
    }

    func testShelves() {
        let kart = game("kart", "Kart", author: "Mia", tags: ["racing", "cars"], parts: 900, days: 1)
        let boat = game("boat", "Boat Race", author: "mia", tags: ["racing", "water"], parts: 40, days: 5)
        let party = game("party", "Party", tags: ["party"], parts: 200, players: 12, days: 3)
        let cafe = game("cafe", "Cafe", tags: ["cute"], parts: 10, days: 2)
        let all = [kart, boat, party, cafe]

        XCTAssertEqual(GameShelves.notPlayed(all, played: ["kart"]).map(\.id), ["boat", "party", "cafe"])
        XCTAssertEqual(GameShelves.similar(to: kart, in: all).map(\.id), ["boat"])
        let liked = GameShelves.becauseYouLiked(all, likedInOrder: ["cafe", "kart"], played: [])
        XCTAssertEqual(liked?.source.id, "kart", "cafe has nothing like it; kart does")
        XCTAssertEqual(liked?.games.map(\.id), ["boat"])
        XCTAssertNil(GameShelves.becauseYouLiked(all, likedInOrder: ["kart"], played: ["boat"]))
        XCTAssertEqual(GameShelves.quickToLoad(all, limit: 2).map(\.id), ["cafe", "boat"])
        XCTAssertEqual(GameShelves.betterTogether(all).map(\.id), ["party"])
        let lastPlayed = ["kart": Date(timeIntervalSince1970: 1_700_000_000), "boat": Date(timeIntervalSince1970: 1_800_000_000)]
        XCTAssertEqual(GameShelves.updatedSincePlayed(all, lastPlayed: lastPlayed).map(\.id), ["kart"])
        XCTAssertEqual(GameShelves.byAuthor(of: kart, in: all).map(\.id), ["boat"])
        XCTAssertEqual(GameShelves.tagCounts(in: all).first?.tag, "racing")
        XCTAssertEqual(GameShelves.tagCounts(in: all).first?.count, 2)

        // The same all week, whoever asks.
        let monday = Date(timeIntervalSince1970: 1_790_000_000)
        let pick = GameShelves.weeklyPick(from: all, on: monday)
        XCTAssertNotNil(pick)
        XCTAssertEqual(GameShelves.weeklyPick(from: all.reversed(), on: monday)?.id, pick?.id)
        XCTAssertNil(GameShelves.weeklyPick(from: [], on: monday))

        var viewed = RecentlyViewed()
        for n in 0..<20 { viewed.viewed("g\(n)") }
        viewed.viewed("g5")
        XCTAssertEqual(viewed.games.first, "g5")
        XCTAssertEqual(viewed.games.count, RecentlyViewed.kept)
    }
}
