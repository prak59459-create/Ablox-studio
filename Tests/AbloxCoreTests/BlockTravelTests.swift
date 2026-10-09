import XCTest
@testable import AbloxCore

/// Blocks on their way somewhere: a character walking a long carpet must be
/// seen walking by someone who joins halfway, and must not jump to the end of
/// the carpet when its words change (Meme Heist, from the suggestion box).
final class BlockTravelTests: RuntimeTestCase {

    private let carol = PeerID()

    private func walkerGame(_ extra: String = "") -> (GameRuntime, BlockData) {
        var world = WorldDocument(name: "Carpet")
        let walker = BlockData(name: "Walker")
        world.insert(walker)
        let game = game("on start()\n  block(\"Walker\").move_to({x: 100, y: 1, z: 0}, 10)\nend\n" + extra, world: world)
        return (game, walker)
    }

    func testSomeoneJoiningHalfwaySeesTheBlockWhereItIsAndTheRestOfTheTrip() throws {
        let (game, walker) = walkerGame()
        startWithBoth(game)
        game.advance(to: 4)
        let before = game.travels
        game.addPlayer(snapshot(carol, "Carol"))
        let joining = game.joiningWorld(for: carol, before: before)

        XCTAssertEqual(game.world.block(id: walker.id)?.position, Vec3(100, 1, 0), "the host's map has the end")
        let position = try XCTUnwrap(joining.world.block(id: walker.id)?.position)
        XCTAssertEqual(position.x, 40, accuracy: 0.01, "4 of 10 seconds along")
        XCTAssertEqual(joining.effects.count, 1)
        let effect = try XCTUnwrap(joining.effects.first)
        XCTAssertEqual(effect.targetPeerID, carol, "only for the one joining")
        guard case let .move(id, offset, duration) = effect.action else { return XCTFail("a move") }
        XCTAssertEqual(id, walker.id)
        XCTAssertEqual(offset.x, 60, accuracy: 0.01)
        XCTAssertEqual(duration, 6, accuracy: 0.01)
    }

    func testATripThatIsOverIsNotCaughtUp() {
        let (game, walker) = walkerGame()
        startWithBoth(game)
        game.advance(to: 11)
        XCTAssertTrue(game.travels.isEmpty)
        let joining = game.joiningWorld(for: carol, before: game.travels)
        XCTAssertEqual(joining.world.block(id: walker.id)?.position, Vec3(100, 1, 0))
        XCTAssertTrue(joining.effects.isEmpty)
    }

    func testABlockPutSomewhereElseIsNotCaughtUp() {
        let (game, walker) = walkerGame("on chat(p, t)\n  block(\"Walker\").position = {x: 5, y: 0, z: 0}\nend\n")
        startWithBoth(game)
        game.advance(to: 4)
        game.handleChat(from: alice, text: "stop")
        let joining = game.joiningWorld(for: carol, before: game.travels)
        XCTAssertEqual(joining.world.block(id: walker.id)?.position, Vec3(5, 0, 0))
        XCTAssertTrue(joining.effects.isEmpty)
    }

    func testAChangeHalfwayGoesOutWhereEveryonesCopyHasTheBlock() throws {
        let (game, walker) = walkerGame("on chat(p, t)\n  block(\"Walker\").color = \"red\"\nend\n")
        startWithBoth(game)
        game.advance(to: 4)
        _ = game.drainWorldDeltas()
        game.handleChat(from: alice, text: "red")
        let updates = game.drainWorldDeltas().compactMap { delta -> BlockData? in
            if case let .update(block) = delta, block.id == walker.id { return block }
            return nil
        }
        let sent = try XCTUnwrap(updates.last)
        XCTAssertEqual(sent.position, .zero, "not the end of the trip, which would make it jump there")
        XCTAssertEqual(sent.color, ScriptColor.parse("red"))
        XCTAssertEqual(game.world.block(id: walker.id)?.position, Vec3(100, 1, 0))

        game.advance(to: 10.5)
        let finished = game.drainWorldDeltas().compactMap { delta -> BlockData? in
            if case let .update(block) = delta, block.id == walker.id { return block }
            return nil
        }
        XCTAssertEqual(finished.last?.position, Vec3(100, 1, 0), "the end position when the trip is over")
    }

    func testLongTripsGoAtASteadySpeed() {
        XCTAssertTrue(BlockTravel.isSteady(duration: 77))
        XCTAssertTrue(BlockTravel.isSteady(duration: 2))
        XCTAssertFalse(BlockTravel.isSteady(duration: 0.5), "a door still eases")
        let travel = BlockTravel(from: Vec3(-122, 0, 0), offset: Vec3(246, 0, 0), start: 10, duration: 80)
        XCTAssertEqual(travel.position(at: 50).x, 1, accuracy: 0.001)
        XCTAssertEqual(travel.position(at: 0), Vec3(-122, 0, 0))
        XCTAssertEqual(travel.position(at: 500), Vec3(124, 0, 0))
    }

    func testAPartIsShiftedWithTheTravellingBlockItHangsFrom() {
        let root = UUID()
        let body = UUID()
        let eye = UUID()
        let other = UUID()
        let parents = [body: root, eye: body]
        let lookUp: (UUID) -> UUID? = { parents[$0] }
        XCTAssertEqual(BlockTravel.travellingAncestor(of: eye, travelling: [root], parent: lookUp), root)
        XCTAssertEqual(BlockTravel.travellingAncestor(of: root, travelling: [root], parent: lookUp), root)
        XCTAssertNil(BlockTravel.travellingAncestor(of: other, travelling: [root], parent: lookUp))
        XCTAssertNil(BlockTravel.travellingAncestor(of: eye, travelling: [], parent: lookUp))

        let box = BoundingBox(center: Vec3(-122, 1, 0), size: Vec3(2, 2, 2))
        XCTAssertEqual(box.offset(by: Vec3(120, 0, 0)).center, Vec3(-2, 1, 0))
    }
}
