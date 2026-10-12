import XCTest
@testable import AbloxCore

/// Studio's Play button opens the game itself, not only the physics view.
final class TestPlayTests: XCTestCase {

    func testPlayOpensTheGame() {
        XCTAssertEqual(TestPlay.choice(isSharingFromHere: false), .game)
    }

    func testSharingFromHereFallsBackToThePreview() {
        // The shared room holds the game's port, so a test game could not
        // start beside it.
        XCTAssertEqual(TestPlay.choice(isSharingFromHere: true), .preview)
    }

    func testTheWorldIsTestedAsItIsInTheEditor() {
        var world = WorldDocument.blank(named: "Scripts online")
        world.scriptSource = ScriptSource(repository: "someone/game", updatesOnPlay: true)
        let tested = TestPlay.world(world)
        // The scripts being written, never the copy on GitHub.
        XCTAssertEqual(tested.scriptSource?.updatesOnPlay, false)
        XCTAssertEqual(tested.scriptSource?.repository, "someone/game")
        XCTAssertEqual(tested.blocks, world.blocks)
        XCTAssertEqual(tested.name, world.name)
    }

    func testAWorldWithoutScriptsOnlineIsUnchanged() {
        let world = WorldDocument.blank(named: "Plain")
        XCTAssertNil(TestPlay.world(world).scriptSource)
        XCTAssertEqual(TestPlay.world(world).blocks, world.blocks)
    }

    func testTheTestedWorldHasSomewhereToStart() {
        // A blank world has a spawn, so the character stands on it rather
        // than falling from the middle of nowhere.
        let world = TestPlay.world(.blank())
        XCTAssertFalse(world.blocks.filter { $0.behavior == .spawn }.isEmpty)
    }
}
