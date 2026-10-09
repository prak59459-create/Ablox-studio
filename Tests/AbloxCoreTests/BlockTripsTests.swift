import XCTest
@testable import AbloxCore

/// Where an iPad draws a block on its way somewhere. A Meme Heist meme
/// walking the carpet must be drawn where the script has it — the buy button
/// showed by an empty carpet (from the suggestion box).
final class BlockTripsTests: XCTestCase {

    private let walker = UUID()

    func testALongTripIsDrawnWhereTheScriptCountsIt() throws {
        var trips = BlockTrips()
        // The carpet: from x = -122, 3.2 m a second.
        trips.start(walker, at: Vec3(-122, 0.22, 0), offset: Vec3(246, 0, 0), duration: 246 / 3.2, clock: 100)
        for seconds in [0.0, 10, 40, 70] {
            let drawn = try XCTUnwrap(trips.position(of: walker, at: 100 + seconds))
            XCTAssertEqual(drawn.x, Float(-122 + 3.2 * seconds), accuracy: 0.01)
            XCTAssertEqual(drawn.y, 0.22, accuracy: 0.0001)
        }
    }

    func testEveryFrameGivesThePlaceAndATripThatIsOverGivesItsEndOnce() throws {
        var trips = BlockTrips()
        trips.start(walker, at: .zero, offset: Vec3(10, 0, 0), duration: 5, clock: 0)
        let halfway = trips.advance(to: 2.5)
        XCTAssertEqual(halfway.count, 1)
        XCTAssertEqual(try XCTUnwrap(halfway.first).position.x, 5, accuracy: 0.01)
        let last = trips.advance(to: 6)
        XCTAssertEqual(try XCTUnwrap(last.first).position, Vec3(10, 0, 0))
        XCTAssertTrue(trips.advance(to: 7).isEmpty)
        XCTAssertTrue(trips.isEmpty)
    }

    func testAShortMoveSpeedsUpAndSlowsDown() throws {
        var trips = BlockTrips()
        trips.start(walker, at: .zero, offset: Vec3(0, 4, 0), duration: 1, clock: 0)
        let early = try XCTUnwrap(trips.position(of: walker, at: 0.1)).y
        XCTAssertLessThan(early, 0.4, "slow to start")
        XCTAssertEqual(try XCTUnwrap(trips.position(of: walker, at: 0.5)).y, 2, accuracy: 0.001)
    }

    func testAMoveThatComesBeforeItsBlockSetsOffWhenTheBlockAppears() throws {
        var trips = BlockTrips()
        trips.hold(walker, offset: Vec3(32, 0, 0), duration: 10, clock: 50)
        XCTAssertNil(trips.position(of: walker, at: 50))
        XCTAssertTrue(trips.appeared(walker, at: Vec3(-122, 0.22, 0), clock: 50.5))
        // As far along as it would be had it been drawn from the start.
        XCTAssertEqual(try XCTUnwrap(trips.position(of: walker, at: 55)).x, -106, accuracy: 0.01)
        XCTAssertTrue(trips.mapHas(walker, at: Vec3(-122, 0.22, 0), previously: nil), "the block just drawn")
    }

    func testAMoveLongGoneDoesNotStartWhenItsBlockFinallyAppears() {
        var trips = BlockTrips()
        trips.hold(walker, offset: Vec3(5, 0, 0), duration: 1, clock: 0)
        XCTAssertFalse(trips.appeared(walker, at: .zero, clock: 60))
        XCTAssertTrue(trips.isEmpty)
    }

    func testNewWordsOnTheWayAndTheMapCatchingUpKeepTheTrip() throws {
        var trips = BlockTrips()
        trips.start(walker, at: .zero, offset: Vec3(20, 0, 0), duration: 10, clock: 0)
        XCTAssertTrue(trips.mapHas(walker, at: .zero, previously: .zero), "a sale price on the way")
        XCTAssertTrue(trips.mapHas(walker, at: Vec3(20, 0, 0), previously: .zero), "the end, a moment early")
        XCTAssertEqual(try XCTUnwrap(trips.position(of: walker, at: 5)).x, 10, accuracy: 0.01)
    }

    func testABlockAScriptPutsElsewhereStopsTravelling() {
        var trips = BlockTrips()
        trips.start(walker, at: .zero, offset: Vec3(20, 0, 0), duration: 10, clock: 0)
        XCTAssertFalse(trips.mapHas(walker, at: Vec3(3, 3, 3), previously: .zero))
        XCTAssertNil(trips.position(of: walker, at: 5))
    }

    func testASecondMoveOnTheWayGoesFromWhereItIsToWhereTheMapHasIt() throws {
        var trips = BlockTrips()
        trips.start(walker, at: .zero, offset: Vec3(20, 0, 0), duration: 10, clock: 0)
        let now = try XCTUnwrap(trips.position(of: walker, at: 5))
        trips.start(walker, at: now, offset: Vec3(0, 0, 4), duration: 2, clock: 5)
        XCTAssertEqual(try XCTUnwrap(trips.position(of: walker, at: 5)).x, 10, accuracy: 0.01, "no jump")
        let end = try XCTUnwrap(trips.position(of: walker, at: 7))
        XCTAssertEqual(end.x, 20, accuracy: 0.01)
        XCTAssertEqual(end.z, 4, accuracy: 0.01)
    }

    func testAMoveAtOnceGoesStraightThere() throws {
        var trips = BlockTrips()
        trips.start(walker, at: Vec3(1, 0, 0), offset: Vec3(0, 2, 0), duration: 0, clock: 3)
        XCTAssertEqual(try XCTUnwrap(trips.advance(to: 3).first).position, Vec3(1, 2, 0))
        XCTAssertTrue(trips.isEmpty)
    }
}
