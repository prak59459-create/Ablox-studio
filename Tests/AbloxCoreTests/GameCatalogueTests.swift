import XCTest
@testable import AbloxCore

/// The catalogue is the first part of Ablox that reads bytes written by
/// someone who is not the person holding the iPad.
///
/// Everything a listing says is a claim: a path it wants joined to a URL and
/// to a cache directory, a size, a name. These tests are mostly about what
/// happens when those claims are hostile, because that is the case nobody
/// exercises by hand and the one that matters.
final class GameCatalogueTests: XCTestCase {

    // MARK: Identifiers

    func testOrdinarySlugsAreAccepted() {
        for id in ["sky-temple", "a", "level-2", "the-very-long-one-9"] {
            XCTAssertTrue(GameCatalogue.Limits.isValidID(id), id)
        }
    }

    func testAnIDCannotClimbOutOfTheCacheDirectory() {
        // The id becomes a folder name. These are the spellings that would
        // make it a different folder.
        for id in ["..", ".", "../etc", "a/b", "a\\b", "/absolute", "~/home", "a\0b"] {
            XCTAssertFalse(GameCatalogue.Limits.isValidID(id), "\(id) must not be a usable id")
        }
    }

    func testAnIDIsLowercaseOnly() {
        // An iPad's filesystem is case-insensitive, so "Temple" and "temple"
        // would be the same folder but two different listings — the second
        // download would silently overwrite the first.
        XCTAssertFalse(GameCatalogue.Limits.isValidID("Sky-Temple"))
        XCTAssertFalse(GameCatalogue.Limits.isValidID("SKY"))
        XCTAssertTrue(GameCatalogue.Limits.isValidID("sky-temple"))
    }

    func testAnIDIsASCIIOnly() {
        // Two ids that normalise to the same string on disk would collide;
        // refusing non-ASCII avoids having to reason about it at all.
        XCTAssertFalse(GameCatalogue.Limits.isValidID("そら"))
        XCTAssertFalse(GameCatalogue.Limits.isValidID("café"))
        XCTAssertFalse(GameCatalogue.Limits.isValidID("emoji-🎮"))
    }

    func testHyphenPlacementIsRestricted() {
        // Leading, trailing and doubled hyphens are the usual ways to end up
        // with two ids that read as the same name.
        XCTAssertFalse(GameCatalogue.Limits.isValidID("-temple"))
        XCTAssertFalse(GameCatalogue.Limits.isValidID("temple-"))
        XCTAssertFalse(GameCatalogue.Limits.isValidID("sky--temple"))
    }

    func testAnEmptyOrOverlongIDIsRefused() {
        XCTAssertFalse(GameCatalogue.Limits.isValidID(""))
        XCTAssertFalse(GameCatalogue.Limits.isValidID(String(repeating: "a", count: 65)))
        XCTAssertTrue(GameCatalogue.Limits.isValidID(String(repeating: "a", count: 64)))
    }

    // MARK: Paths

    func testOrdinaryPathsAreAccepted() {
        let ok = ["games/sky-temple/world.ablox", "world.ablox", "a/b/c/d.json"]
        for path in ok {
            XCTAssertTrue(
                GameCatalogue.Limits.isValidRepositoryPath(path, extensions: ["ablox", "json"]),
                path
            )
        }
    }

    func testAPathCannotLeaveTheRepository() {
        // The one that matters. Each of these, joined to a cache directory,
        // writes somewhere the app was never meant to write.
        let attacks = [
            "../world.ablox",
            "games/../../world.ablox",
            "games/./../../world.ablox",
            "/etc/passwd.ablox",
            "~/world.ablox",
            "games//world.ablox",
            "games\\world.ablox",
            "games/\0/world.ablox"
        ]
        for path in attacks {
            XCTAssertFalse(
                GameCatalogue.Limits.isValidRepositoryPath(path, extensions: ["ablox", "json"]),
                "\(path) escapes the repository and must be refused"
            )
        }
    }

    func testAPathCannotNameAnotherServer() {
        // Joined to a base URL, an absolute one would replace it entirely.
        let attacks = [
            "https://example.com/world.ablox",
            "http://example.com/world.ablox",
            "file:///etc/world.ablox",
            "data:application/json;base64,e30=.json",
            "//example.com/world.ablox"
        ]
        for path in attacks {
            XCTAssertFalse(
                GameCatalogue.Limits.isValidRepositoryPath(path, extensions: ["ablox", "json"]),
                "\(path) points off the repository and must be refused"
            )
        }
    }

    func testHiddenFilesAreRefused() {
        // `.git/config` is the interesting one: it is a real path in every
        // repository and nothing honest ever asks for it.
        XCTAssertFalse(GameCatalogue.Limits.isValidRepositoryPath(".git/config.json", extensions: ["json"]))
        XCTAssertFalse(GameCatalogue.Limits.isValidRepositoryPath("games/.hidden/world.ablox", extensions: ["ablox"]))
    }

    func testTheExtensionMustMatchWhatIsBeingFetched() {
        // Stops a cover slot being used to fetch a world, or either being used
        // to pull down an executable.
        XCTAssertFalse(GameCatalogue.Limits.isValidRepositoryPath("games/a/cover.png", extensions: ["ablox", "json"]))
        XCTAssertFalse(GameCatalogue.Limits.isValidRepositoryPath("games/a/thing.sh", extensions: ["png"]))
        XCTAssertTrue(GameCatalogue.Limits.isValidRepositoryPath("games/a/COVER.PNG", extensions: ["png"]),
                      "the extension check is case-insensitive")
    }

    // MARK: URLs

    func testURLsStayOnTheExpectedHost() throws {
        let source = CatalogueSource(repository: "someone/ablox-games")
        let index = try XCTUnwrap(source.indexURL)
        XCTAssertEqual(index.absoluteString,
                       "https://raw.githubusercontent.com/someone/ablox-games/main/index.json")

        let listing = GameListing(id: "sky", title: "Sky", world: "games/sky/world.ablox")
        let world = try XCTUnwrap(source.worldURL(for: listing))
        XCTAssertEqual(world.absoluteString,
                       "https://raw.githubusercontent.com/someone/ablox-games/main/games/sky/world.ablox")
    }

    func testAPathThatFailsValidationProducesNoURLAtAll() {
        // Belt and braces: a caller that forgets to validate still cannot be
        // aimed at another host.
        let source = CatalogueSource(repository: "someone/ablox-games")
        let hostile = GameListing(id: "sky", title: "Sky", world: "https://example.com/evil.ablox")
        XCTAssertNil(source.worldURL(for: hostile))

        let traversal = GameListing(id: "sky", title: "Sky", world: "../../evil.ablox")
        XCTAssertNil(source.worldURL(for: traversal))
    }

    func testPathComponentsArePercentEncoded() throws {
        // Built by appending components rather than by concatenating strings,
        // so a space cannot produce a URL that silently fails to parse.
        let source = CatalogueSource(repository: "someone/ablox-games")
        let listing = GameListing(id: "sky", title: "Sky", world: "games/sky temple/world.ablox")
        let url = try XCTUnwrap(source.worldURL(for: listing))
        XCTAssertTrue(url.absoluteString.contains("sky%20temple"), url.absoluteString)
    }

    func testARepositoryNameCannotBeAURL() {
        // The repository is settable, so this is user input too.
        for bad in ["https://example.com/a/b", "owner", "owner/repo/extra", "/repo", "owner/", "", "own er/repo"] {
            XCTAssertFalse(CatalogueSource(repository: bad).isValidRepository, bad)
            XCTAssertNil(CatalogueSource(repository: bad).indexURL, bad)
        }
        XCTAssertTrue(CatalogueSource(repository: "prak59459-create/ablox-games").isValidRepository)
    }

    func testTheDefaultSourceIsUsable() throws {
        XCTAssertTrue(CatalogueSource.default.isValidRepository)
        XCTAssertNotNil(CatalogueSource.default.indexURL)
        XCTAssertNotNil(CatalogueSource.default.webURL)
    }

    // MARK: Decoding

    private func indexData(_ json: String) -> Data { Data(json.utf8) }

    func testAWellFormedIndexDecodes() throws {
        let catalogue = try GameCatalogue.decode(indexData: indexData("""
        {
          "catalogueVersion": 1,
          "updatedAt": "2026-09-19T00:00:00Z",
          "games": [
            {
              "id": "sky-temple",
              "title": "Sky Temple",
              "author": "Mika",
              "summary": "Climb it.",
              "world": "games/sky-temple/world.ablox",
              "cover": "games/sky-temple/cover.png",
              "tags": ["obstacle"],
              "blockCount": 210,
              "maxPlayers": 4,
              "schemaVersion": 1,
              "updatedAt": "2026-09-19T00:00:00Z"
            }
          ]
        }
        """))

        XCTAssertEqual(catalogue.games.count, 1)
        XCTAssertEqual(catalogue.games[0].title, "Sky Temple")
        XCTAssertEqual(catalogue.validated().accepted.count, 1)
    }

    func testAnIndexFromTheFutureIsRefusedWithAReadableReason() {
        // Rather than decoded into something half-understood.
        let data = indexData("""
        {"catalogueVersion": 99, "updatedAt": "2026-09-19T00:00:00Z", "games": []}
        """)
        XCTAssertThrowsError(try GameCatalogue.decode(indexData: data)) { error in
            guard let error = error as? CatalogueError else { return XCTFail("wrong error") }
            XCTAssertEqual(error.rejection, .wrongVersion(found: 99, supported: 1))
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testAnOversizedIndexIsRefusedBeforeItIsParsed() {
        // The limit is on the bytes, not on what they decode to: parsing a
        // hostile 50 MB document to find out it is too big is the problem.
        let data = Data(repeating: 0x20, count: GameCatalogue.Limits.maximumIndexBytes + 1)
        XCTAssertThrowsError(try GameCatalogue.decode(indexData: data)) { error in
            guard let error = error as? CatalogueError else { return XCTFail("wrong error") }
            guard case .tooLarge = error.rejection else { return XCTFail("expected .tooLarge") }
        }
    }

    func testMalformedJSONIsAnErrorRatherThanACrash() {
        XCTAssertThrowsError(try GameCatalogue.decode(indexData: indexData("{not json"))) { error in
            guard let error = error as? CatalogueError else { return XCTFail("wrong error") }
            guard case .malformed = error.rejection else { return XCTFail("expected .malformed") }
        }
    }

    // MARK: Partial validation

    private func listing(_ id: String, world: String = "games/x/world.ablox") -> GameListing {
        GameListing(id: id, title: "Title", world: world, blockCount: 1)
    }

    func testOneBadListingDoesNotThrowAwayTheCatalogue() {
        // A repository anyone can open a pull request against will contain a
        // typo eventually. Hiding nine hundred working games because of it
        // would be the wrong trade.
        let catalogue = GameCatalogue(games: [
            listing("good-one"),
            listing("BAD-CASE"),
            listing("also-good"),
            listing("traversal", world: "../../etc/passwd.ablox")
        ])

        let result = catalogue.validated()
        XCTAssertEqual(result.accepted.map(\.id), ["good-one", "also-good"])
        XCTAssertEqual(result.rejected.count, 2)
    }

    func testDuplicateIDsKeepTheFirstOnly() {
        // They would be the same cache folder, so the second download would
        // quietly replace the first — and which one you got would depend on
        // list order.
        let catalogue = GameCatalogue(games: [
            GameListing(id: "sky", title: "First", world: "games/a/world.ablox"),
            GameListing(id: "sky", title: "Second", world: "games/b/world.ablox")
        ])

        let result = catalogue.validated()
        XCTAssertEqual(result.accepted.map(\.title), ["First"])
        XCTAssertEqual(result.rejected.first?.reason, .duplicateID("sky"))
    }

    func testAWorldFromANewerStudioIsRejectedButNamed() {
        // Worth telling someone about, unlike a traversal attempt.
        var listing = self.listing("future")
        listing.schemaVersion = WorldDocument.currentSchemaVersion + 1
        XCTAssertEqual(
            listing.rejection(),
            .unsupportedSchema(id: "future", schemaVersion: WorldDocument.currentSchemaVersion + 1)
        )
        XCTAssertFalse(listing.isSupported)
    }

    func testOverlongTextFieldsAreRejected() {
        var long = listing("long")
        long.title = String(repeating: "a", count: 61)
        XCTAssertEqual(long.rejection(), .fieldTooLong(field: "title", limit: 60))

        var summary = listing("summary")
        summary.summary = String(repeating: "a", count: 281)
        XCTAssertEqual(summary.rejection(), .fieldTooLong(field: "summary", limit: 280))
    }

    func testAnEmptyTitleIsRejected() {
        var blank = listing("blank")
        blank.title = ""
        XCTAssertNotNil(blank.rejection())
    }

    func testTooManyTagsAreRejected() {
        var tagged = listing("tagged")
        tagged.tags = Array(repeating: "tag", count: 9)
        XCTAssertNotNil(tagged.rejection())
    }

    func testACoverIsOptionalButValidatedWhenPresent() {
        var none = listing("no-cover")
        none.cover = nil
        XCTAssertNil(none.rejection())

        var hostile = listing("bad-cover")
        hostile.cover = "../../../secret.png"
        XCTAssertEqual(hostile.rejection(), .invalidPath(field: "cover", value: "../../../secret.png"))
    }

    // MARK: Claims about content

    func testAStaleBlockCountIsReported() {
        // Not a security check — the world is already decoded by then. It
        // catches an index edited by hand and never updated.
        let listing = GameListing(id: "sky", title: "Sky", world: "games/sky/world.ablox", blockCount: 100)
        var world = WorldDocument(name: "Sky")
        world.blocks = [BlockData(name: "One")]

        XCTAssertNotNil(listing.mismatch(with: world))

        var honest = listing
        honest.blockCount = 1
        XCTAssertNil(honest.mismatch(with: world))
    }

    func testRoundTripThroughJSON() throws {
        // The index is written by Studio's publish flow and read back here, so
        // the two have to agree on the encoding — dates especially.
        let original = GameCatalogue(games: [
            GameListing(id: "sky-temple", title: "Sky Temple", author: "Mika",
                        summary: "Climb it.", world: "games/sky-temple/world.ablox",
                        cover: "games/sky-temple/cover.png", tags: ["obstacle"],
                        blockCount: 210, maxPlayers: 4)
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoded = try GameCatalogue.decode(indexData: data)
        XCTAssertEqual(decoded.games.map(\.id), original.games.map(\.id))
        XCTAssertEqual(decoded.games[0].cover, "games/sky-temple/cover.png")
        XCTAssertEqual(decoded.validated().rejected.count, 0)
    }

    // MARK: Drafting a listing

    func testATitleBecomesASlug() {
        XCTAssertEqual(GameListing.suggestedID(for: "Sky Temple"), "sky-temple")
        XCTAssertEqual(GameListing.suggestedID(for: "  Lava   Cave!!  "), "lava-cave")
        XCTAssertEqual(GameListing.suggestedID(for: "Level 2: The Return"), "level-2-the-return")
    }

    func testEverySuggestedIDIsActuallyValid() {
        // The property that matters: whatever someone types as a title, the
        // id Studio proposes must be one the catalogue accepts.
        let titles = [
            "Sky Temple", "  ", "---", "!!!", "そらのしんでん", "Café Noir",
            "🎮🎮🎮", String(repeating: "Very Long Title ", count: 20),
            "a", "-leading", "trailing-", "double--hyphen"
        ]
        for title in titles {
            let id = GameListing.suggestedID(for: title)
            XCTAssertTrue(GameCatalogue.Limits.isValidID(id), "“\(title)” produced “\(id)”")
        }
    }

    func testATitleWithNoASCIIStillGetsAStableID() {
        // A Japanese title survives none of the slug rules, so it falls back
        // to a hash — which still has to be the same hash every time, or
        // republishing the same world would create a second listing.
        let first = GameListing.suggestedID(for: "そらのしんでん")
        let second = GameListing.suggestedID(for: "そらのしんでん")
        XCTAssertEqual(first, second)
        XCTAssertTrue(GameCatalogue.Limits.isValidID(first))
        XCTAssertNotEqual(first, GameListing.suggestedID(for: "べつのせかい"))
    }

    func testADraftListingPassesValidation() {
        var world = WorldDocument(name: "Sky Temple")
        world.blocks = [BlockData(name: "A"), BlockData(name: "B")]

        let listing = GameListing.draft(for: world, author: "Mika")
        XCTAssertNil(listing.rejection(), "Studio must not propose a listing the app would refuse")
        XCTAssertEqual(listing.id, "sky-temple")
        XCTAssertEqual(listing.blockCount, 2)
        XCTAssertEqual(listing.world, "games/sky-temple/world.ablox")
    }

    func testADraftFromAJapaneseTitleAlsoPasses() {
        let world = WorldDocument(name: "そらのしんでん")
        let listing = GameListing.draft(for: world, author: "みか")
        XCTAssertNil(listing.rejection())
    }

    func testAnOverlongTitleIsTrimmedIntoADraftThatValidates() {
        let world = WorldDocument(name: String(repeating: "a", count: 500))
        let listing = GameListing.draft(for: world, author: String(repeating: "b", count: 500))
        XCTAssertNil(listing.rejection())
    }

    func testTheDraftEntryIsJSONTheCatalogueCanReadBack() {
        // The round trip that makes publishing work: what Studio hands someone
        // to paste has to be something the app parses.
        var world = WorldDocument(name: "Sky Temple")
        world.blocks = [BlockData(name: "A")]

        let entry = GameListing.draft(for: world, author: "Mika").indexEntryJSON()
        let index = "{\"catalogueVersion\":1,\"updatedAt\":\"2026-09-19T00:00:00Z\",\"games\":[\(entry)]}"

        let catalogue = try? GameCatalogue.decode(indexData: Data(index.utf8))
        XCTAssertEqual(catalogue?.validated().accepted.count, 1)
    }
}
