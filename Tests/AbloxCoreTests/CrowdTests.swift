import XCTest
@testable import AbloxCore

/// A hundred on one field: who is near whom, slipping through a crowd, and
/// how much care far people get on screen.
final class CrowdTests: XCTestCase {

    func testTheGridFindsTheNearestFewOnly() {
        var members: [(id: Int, position: Vec3)] = []
        for i in 0..<100 { members.append((i, Vec3(Float(i % 10), 0, Float(i / 10)))) }
        let grid = CrowdGrid(members)
        let near = grid.nearest(to: Vec3(0, 0, 0), within: 4, except: 0)
        XCTAssertEqual(near.count, CrowdGrid<Int>.limit)
        XCTAssertEqual(Set(near.prefix(2).map(\.id)), [1, 10], "the two a metre away come first")
        XCTAssertFalse(near.contains { $0.id == 0 }, "not ourselves")
        XCTAssertTrue(near.allSatisfy { $0.position.distance(to: .zero) < 4 })
    }

    func testTheGridLooksAcrossSquares() {
        let grid = CrowdGrid([(id: "a", position: Vec3(3.9, 0, 0)), (id: "b", position: Vec3(4.1, 0, 0)),
                              (id: "c", position: Vec3(-0.2, 0, -0.2)), (id: "far", position: Vec3(20, 0, 0))])
        let near = grid.nearest(to: Vec3(1, 0, 0), within: 4, limit: .max)
        XCTAssertEqual(near.map(\.id), ["c", "a", "b"])
        XCTAssertTrue(grid.nearest(to: Vec3(.nan, 0, 0), within: 4).isEmpty)
    }

    func testTheGridMatchesLookingAtEveryone() {
        var members: [(id: Int, position: Vec3)] = []
        var seed: UInt64 = 7
        func next() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24) * 30 - 15
        }
        for i in 0..<100 { members.append((i, Vec3(next(), 0, next()))) }
        let grid = CrowdGrid(members)
        for probe in members.prefix(20) {
            let everyone = Set(members.filter { $0.id != probe.id && $0.position.distance(to: probe.position) < 4 }.map(\.id))
            let found = Set(grid.nearest(to: probe.position, within: 4, limit: .max, except: probe.id).map(\.id))
            XCTAssertEqual(found, everyone)
        }
    }

    func testThePlayerSlipsThroughACrowdThatHoldsThemUp() {
        var squeeze = CrowdSqueeze()
        for _ in 0..<5 { squeeze.note(wanted: 5, got: 0.2, amongCharacters: true, deltaTime: 1.0 / 30) }
        XCTAssertFalse(squeeze.passesThrough, "a short bump is still a bump")
        for _ in 0..<15 { squeeze.note(wanted: 5, got: 0.2, amongCharacters: true, deltaTime: 1.0 / 30) }
        XCTAssertTrue(squeeze.passesThrough)
        squeeze.note(wanted: 5, got: 0, amongCharacters: false, deltaTime: 1.0 / 30)
        XCTAssertTrue(squeeze.passesThrough, "still slipping through, with no one tested against")
        squeeze.note(wanted: 5, got: 5, amongCharacters: false, deltaTime: 1.0 / 30)
        XCTAssertFalse(squeeze.passesThrough, "walking freely again: people are solid again")
    }

    func testAWallAloneNeverLetsThePlayerThrough() {
        var squeeze = CrowdSqueeze()
        for _ in 0..<60 { squeeze.note(wanted: 5, got: 0, amongCharacters: false, deltaTime: 1.0 / 30) }
        XCTAssertFalse(squeeze.passesThrough)
        for _ in 0..<60 { squeeze.note(wanted: 0, got: 0, amongCharacters: true, deltaTime: 1.0 / 30) }
        XCTAssertFalse(squeeze.passesThrough, "standing still among people is not being held up")
    }

    func testFarPeopleArePosedInTurns() {
        let ranks = CrowdDetail.ranks((0..<100).map { (id: $0, distance: Float(99 - $0)) })
        XCTAssertEqual(ranks[99], 0)
        XCTAssertEqual(ranks[0], 99)
        for frame in 0..<6 {
            let posed = (0..<100).filter { CrowdDetail.poses(rank: ranks[$0]!, frame: frame) }
            XCTAssertTrue((84..<100).allSatisfy(posed.contains), "the nearest every frame")
            XCTAssertLessThan(posed.count, 50, "far ones take turns")
        }
        for rank in 0..<100 {
            XCTAssertTrue((0..<CrowdDetail.turns).contains { CrowdDetail.poses(rank: rank, frame: $0) },
                          "everyone is posed within a few frames")
        }
    }

    func testTiedDistancesKeepTheirOrder() {
        let ranks = CrowdDetail.ranks([(id: "a", distance: 2), (id: "b", distance: 1), (id: "c", distance: 2)])
        XCTAssertEqual(ranks, ["b": 0, "a": 1, "c": 2])
    }
}
