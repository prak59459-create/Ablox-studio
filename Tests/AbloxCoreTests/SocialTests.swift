import XCTest
@testable import AbloxCore

/// Task 7 — chat filtering and muting.
final class ChatModerationTests: XCTestCase {

    private let moderator = ChatModerator()

    func testBlockedWordsAreMasked() {
        let result = moderator.filter("you are stupid")
        XCTAssertEqual(result.text, "you are ******")
        XCTAssertTrue(result.wasFiltered)
    }

    func testMaskingPreservesLength() {
        // The shape of the message still reads, which is the point of masking
        // rather than deleting.
        let result = moderator.filter("idiot")
        XCTAssertEqual(result.text.count, "idiot".count)
        XCTAssertEqual(result.text, "*****")
    }

    func testCleanMessagesPassThroughUntouched() {
        let result = moderator.filter("want to build a castle?")
        XCTAssertEqual(result.text, "want to build a castle?")
        XCTAssertFalse(result.wasFiltered)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(moderator.filter("STUPID").wasFiltered)
        XCTAssertTrue(moderator.filter("StUpId").wasFiltered)
    }

    func testOrdinaryWordsContainingABlockedSubstringSurvive() {
        // The failure that teaches children the filter is broken.
        for innocent in ["classic", "assignment", "Scunthorpe", "crapulence"] {
            let result = moderator.filter(innocent)
            XCTAssertFalse(result.wasFiltered, "\(innocent) should not be filtered, got \(result.text)")
            XCTAssertEqual(result.text, innocent)
        }
    }

    func testMultiWordPhrasesAreMaskedWhole() {
        let result = moderator.filter("just shut up")
        XCTAssertTrue(result.wasFiltered)
        XCTAssertFalse(result.text.contains("shut"))
        XCTAssertFalse(result.text.contains("up"), "the phrase must go as one, not leave a fragment")
    }

    func testEveryOccurrenceIsMasked() {
        let result = moderator.filter("stupid stupid stupid")
        XCTAssertFalse(result.text.contains("stupid"))
        XCTAssertEqual(result.text, "****** ****** ******")
    }

    func testHostsCanExtendTheList() {
        let strict = ChatModerator(additionalTerms: ["banana"])
        XCTAssertTrue(strict.filter("banana").wasFiltered)
        XCTAssertFalse(moderator.filter("banana").wasFiltered)
    }

    func testFilteringCanBeTurnedOff() {
        let off = ChatModerator(isFilterEnabled: false)
        let result = off.filter("stupid")
        XCTAssertEqual(result.text, "stupid")
        XCTAssertFalse(result.wasFiltered)
    }

    func testEmptyAndWhitespaceAreHandled() {
        XCTAssertFalse(moderator.filter("").wasFiltered)
        XCTAssertFalse(moderator.filter("   ").wasFiltered)
    }

    func testFilteringTerminatesOnPathologicalInput() {
        // A masked term is the same length as the original, so a naive
        // implementation can re-match its own output forever.
        let long = String(repeating: "stupid ", count: 200)
        let result = moderator.filter(long)
        XCTAssertTrue(result.wasFiltered)
        XCTAssertEqual(result.text.count, long.count)
    }
}

final class MuteListTests: XCTestCase {

    private let me = PeerID()
    private let noisy = PeerID()
    private let friend = PeerID()

    func testMutingHidesThatPlayerOnly() {
        var list = MuteList()
        list.mute(noisy)

        XCTAssertFalse(list.allows(noisy, localPeerID: me))
        XCTAssertTrue(list.allows(friend, localPeerID: me))
    }

    func testYouCanNeverMuteYourself() {
        var list = MuteList()
        list.mute(me)
        XCTAssertTrue(list.allows(me, localPeerID: me),
                      "dropping your own messages would read as the app being broken")
    }

    func testToggleReportsTheNewState() {
        var list = MuteList()
        XCTAssertTrue(list.toggle(noisy), "first toggle mutes")
        XCTAssertTrue(list.isMuted(noisy))
        XCTAssertFalse(list.toggle(noisy), "second toggle unmutes")
        XCTAssertFalse(list.isMuted(noisy))
    }

    func testMutingIsIdempotent() {
        var list = MuteList()
        list.mute(noisy)
        list.mute(noisy)
        XCTAssertEqual(list.count, 1)
    }

    func testUnmutingSomeoneNotMutedIsHarmless() {
        var list = MuteList()
        list.unmute(noisy)
        XCTAssertTrue(list.isEmpty)
    }

    func testMuteListPersists() throws {
        var list = MuteList()
        list.mute(noisy)
        let restored = try JSONDecoder().decode(MuteList.self, from: JSONEncoder().encode(list))
        XCTAssertTrue(restored.isMuted(noisy))
        XCTAssertFalse(restored.isMuted(friend))
    }
}
