import XCTest
@testable import AbloxCore

/// A hundred NPCs arriving at once (Last Survivor Games) froze the iPad,
/// because every avatar was built in the same frame.
final class RosterArrivalsTests: XCTestCase {

    private let me = PeerID()

    private func npc() -> PlayerSnapshot { PlayerSnapshot(peerID: PeerID(), isNPC: true) }

    func testAHundredNPCsAreDrawnAFewAtATime() {
        let friend = PlayerSnapshot(peerID: PeerID())
        let roster = [PlayerSnapshot(peerID: me)] + (1...99).map { _ in npc() } + [friend]
        var drawn = Set<PeerID>()
        var frames = 0
        while true {
            let batch = RosterArrivals.toDraw(roster, except: me) { drawn.contains($0) }
            if batch.isEmpty { break }
            XCTAssertLessThanOrEqual(batch.count, RosterArrivals.perFrame)
            if frames == 0 {
                XCTAssertEqual(batch.first?.peerID, friend.peerID, "a person is drawn before the NPCs")
            }
            for player in batch {
                XCTAssertFalse(drawn.contains(player.peerID), "nobody is built twice")
                drawn.insert(player.peerID)
            }
            frames += 1
        }
        XCTAssertEqual(drawn.count, 100)
        XCTAssertFalse(drawn.contains(me), "our own avatar is drawn on its own")
        XCTAssertEqual(frames, 25)
    }

    func testNothingWaitingDrawsNothing() {
        let roster = [npc(), npc()]
        let ids = Set(roster.map(\.peerID))
        XCTAssertTrue(RosterArrivals.toDraw(roster, except: me) { ids.contains($0) }.isEmpty)
        XCTAssertTrue(RosterArrivals.toDraw(roster, except: me, limit: 0) { _ in false }.isEmpty)
    }
}
