import XCTest
@testable import AbloxCore

final class SoundLibraryTests: XCTestCase {

    private let hash = String(repeating: "ab", count: 32)

    private func index(_ families: String) -> Data {
        Data("""
        {"version": 1, "license": "CC0-1.0", "source": "SFXMint (https://sfxmint.com)", "updated": "2026-10-10",
         "categories": [{"id": "retro-game", "en": "Retro game", "ja": "レトロゲーム"},
                        {"id": "animal", "en": "Animals", "ja": "動物", "k": "どうぶつ"}],
         "families": [\(families)]}
        """.utf8)
    }

    private var sample: SoundLibrary {
        get throws {
            try SoundLibrary.decode(indexData: index("""
            {"id": "retro-game-coin", "en": "8-Bit Coin Pickup", "ja": "8ビット コイン ゲット", "k": "おかね ひろう", "c": "retro-game",
             "s": [["retro-game-coin-08", 1031, 16927, "\(hash)", "Short 8-Bit Coin Pickup 08"],
                   ["retro-game-coin-33", 2038, 33061, "\(hash)"]]},
            {"id": "animal-dog-bark", "en": "Dog Bark", "ja": "イヌ いぬ ほえる", "c": "animal",
             "s": [["animal-dog-bark-02", 1200, 20000, "\(hash)", "Two Clear Dog Barks 02"]]}
            """))
        }
    }

    func testLibraryIDsAreHyphenatedLowercaseWords() {
        XCTAssertTrue(SoundLibrary.isLibraryID("retro-game-coin-08"))
        XCTAssertTrue(SoundLibrary.isLibraryID("owner-backlog-20260922-decrease-ui-cue"))
        // The built-in cues are one word, so they can never be mistaken.
        for cue in SoundCue.allCases {
            XCTAssertFalse(SoundLibrary.isLibraryID(cue.rawValue), cue.rawValue)
        }
        for name in ["", "-coin", "coin-", "coin--08", "Coin-08", "coin 08", "coin_08", "../etc-passwd", "コイン-01",
                     String(repeating: "a-", count: 60) + "b"] {
            XCTAssertFalse(SoundLibrary.isLibraryID(name), name)
        }
    }

    func testTheIndexIsRead() throws {
        let library = try sample
        XCTAssertEqual(library.soundCount, 3)
        XCTAssertEqual(library.totalBytes, 16927 + 33061 + 20000)
        XCTAssertEqual(library.license, "CC0-1.0")
        let coin = try XCTUnwrap(library.sound("retro-game-coin-08"))
        XCTAssertEqual(coin.path, "sounds/retro-game/retro-game-coin-08.mp3")
        XCTAssertEqual(coin.title, "Short 8-Bit Coin Pickup 08")
        XCTAssertEqual(coin.shortName, "08")
        XCTAssertEqual(coin.milliseconds, 1031)
        XCTAssertEqual(library.sound("retro-game-coin-33")?.title, "", "a title is optional")
        XCTAssertEqual(library.family(of: "animal-dog-bark-02")?.english, "Dog Bark")
        XCTAssertEqual(library.families(in: "animal").map(\.id), ["animal-dog-bark"])
        XCTAssertEqual(library.category("animal")?.japanese, "動物")
    }

    func testSoundsThatCannotBeWhatTheyClaimAreLeftOut() throws {
        let library = try SoundLibrary.decode(indexData: index("""
            {"id": "mixed", "en": "Mixed", "c": "animal",
             "s": [["good-sound-01", 500, 1000, "\(hash)"],
                   ["Bad-Sound", 500, 1000, "\(hash)"],
                   ["short-hash-01", 500, 1000, "abc"],
                   ["not-hex-01", 500, 1000, "\(String(repeating: "zz", count: 32))"],
                   ["too-big-01", 500, 99999999, "\(hash)"],
                   ["empty-file-01", 500, 0, "\(hash)"]]},
            {"id": "../escape", "en": "Escape", "c": "animal", "s": [["escape-01", 1, 1, "\(hash)"]]},
            {"id": "bad-category", "en": "Bad", "c": "../x", "s": [["bad-category-01", 1, 1, "\(hash)"]]}
            """))
        XCTAssertEqual(library.families.map(\.id), ["mixed"])
        XCTAssertEqual(library.families.first?.sounds.map(\.id), ["good-sound-01"])
    }

    func testABrokenOrNewerIndexIsRefused() {
        XCTAssertThrowsError(try SoundLibrary.decode(indexData: Data("not json".utf8))) {
            XCTAssertEqual($0 as? SoundLibraryError, .unreadable)
        }
        let newer = Data(#"{"version": 2, "categories": [], "families": []}"#.utf8)
        XCTAssertThrowsError(try SoundLibrary.decode(indexData: newer)) {
            XCTAssertEqual($0 as? SoundLibraryError, .newerVersion)
        }
    }

    func testSearchFindsEnglishJapaneseAndIDs() throws {
        let library = try sample
        XCTAssertEqual(library.search("coin").map(\.id), ["retro-game-coin"])
        XCTAssertEqual(library.search("COIN pickup").map(\.id), ["retro-game-coin"])
        XCTAssertEqual(library.search("いぬ").map(\.id), ["animal-dog-bark"])
        XCTAssertEqual(library.search("コイン").map(\.id), ["retro-game-coin"])
        XCTAssertEqual(library.search("動物").map(\.id), ["animal-dog-bark"], "a category's name finds its sounds")
        XCTAssertEqual(library.search("どうぶつ").map(\.id), ["animal-dog-bark"], "and its other words")
        XCTAssertEqual(library.search("おかね").map(\.id), ["retro-game-coin"], "a family's other words count")
        XCTAssertEqual(library.search("retro-game-coin-33").map(\.id), ["retro-game-coin"])
        XCTAssertEqual(library.search("clear barks").map(\.id), ["animal-dog-bark"], "a take's own title counts")
        XCTAssertEqual(library.search("coin", category: "animal"), [])
        XCTAssertEqual(library.search("").count, 2)
        XCTAssertEqual(library.search("coin dog"), [], "every word must match")
    }

    func testIDsAreFoundInScriptsAndRules() {
        let source = """
        -- don't forget: "not-this-one" is in a comment
        on touch(p, b)
          sound("retro-game-coin-08")
          p.sound('animal-dog-bark-02', {volume: 0.5})
          sound("coin")
          sound("retro-game-coin-08")
          announce("red-team wins")
        end
        """
        XCTAssertEqual(SoundLibrary.ids(inScripts: [source]), ["retro-game-coin-08", "animal-dog-bark-02"])

        var world = WorldDocument(name: "Sounds")
        world.rules = [EventRule(name: "ding", trigger: .timer(interval: 1), actions: [.playSound(name: "ui-chime-15"), .playSound(name: "goal")])]
        world.scripts = [ScriptFile(name: "main", source: source),
                         ScriptFile(name: "off", source: "sound(\"switched-off-01\")", isEnabled: false)]
        XCTAssertEqual(SoundLibrary.ids(in: world), ["ui-chime-15", "retro-game-coin-08", "animal-dog-bark-02"])
    }

    func testScriptsCanPlayLibrarySounds() {
        var world = WorldDocument(name: "Sounds")
        world.scripts = [ScriptFile(name: "main", source: """
        on start()
          sound("retro-game-coin-08")
          sound("Coin")
          sound("animal-dog-bark-02", {volume: 0.5, pitch: 2})
        end
        """)]
        let game = GameRuntime(world: world)
        let actions = game.handle(.roundStarted).map(\.action)
        XCTAssertTrue(actions.contains(.playSound(name: "retro-game-coin-08")))
        XCTAssertTrue(actions.contains(.playSound(name: "coin")))
        XCTAssertTrue(actions.contains(.script(.sound(SoundPlay(name: "animal-dog-bark-02", volume: 0.5, pitch: 2)))))
        XCTAssertEqual(game.drainErrors(), [])

        var broken = WorldDocument(name: "Broken")
        broken.scripts = [ScriptFile(name: "main", source: "on start()\n  sound(\"kerplunk\")\nend")]
        let other = GameRuntime(world: broken)
        _ = other.handle(.roundStarted)
        let error = other.drainErrors().first
        XCTAssertEqual(error?.line, 2)
        XCTAssertTrue(error?.message.contains("sound library") ?? false)
    }
}
