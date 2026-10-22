import XCTest
@testable import AbloxCore

/// The bell's notifications (8.8).
final class AbloxInboxTests: XCTestCase {

    private func sources() -> AbloxInbox.Sources {
        AbloxInbox.Sources(
            update: (version: AppVersion("9.0")!, required: false),
            notices: [AppNotice(id: "fest", title: ["en": "Festival", "ja": "おまつり"], body: ["en": "Come!", "ja": "きてね！"])],
            requests: [(id: "u1", name: "Mika")],
            friendRooms: [(id: "r1", host: "Ken", world: "Obby")],
            unread: [(id: "u2", name: "Sora")],
            nearby: (name: "Yui", world: "Plaza")
        )
    }

    func testEverySourceBecomesOneItemFriendsFirst() {
        let items = AbloxInbox.items(sources(), language: .english)
        XCTAssertEqual(items.map(\.kind), [.friendNearby, .friendRoom, .friendRequest, .friendMessage, .update, .notice])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique")
        XCTAssertTrue(items[1].title.contains("Ken"))
        XCTAssertTrue(items[4].title.contains("9.0"))
        XCTAssertEqual(items[5].title, "Festival")
    }

    func testNoticesFollowTheLanguage() {
        let items = AbloxInbox.items(AbloxInbox.Sources(notices: sources().notices), language: .japanese)
        XCTAssertEqual(items.first?.title, "おまつり")
    }

    func testNothingKnownIsAnEmptyBell() {
        XCTAssertTrue(AbloxInbox.items(AbloxInbox.Sources(), language: .english).isEmpty)
    }

    func testOpeningTheListMarksEverythingSeenAndTheCountDrops() {
        let items = AbloxInbox.items(sources(), language: .english)
        XCTAssertEqual(AbloxInbox.unseenCount(items, seen: []), 6)
        let seen = AbloxInbox.markingSeen(items, seen: ["old"])
        XCTAssertEqual(AbloxInbox.unseenCount(items, seen: Set(seen)), 0)
        XCTAssertTrue(seen.contains("old"))
        // A new request arrives: one new.
        var more = sources()
        more.requests.append((id: "u3", name: "Aoi"))
        XCTAssertEqual(AbloxInbox.unseenCount(AbloxInbox.items(more, language: .english), seen: Set(seen)), 1)
    }

    func testTheSeenListStaysSmall() {
        let many = (0..<500).map { InboxItem(id: "n\($0)", kind: .notice, title: "", body: "") }
        let seen = AbloxInbox.markingSeen(many, seen: [])
        XCTAssertEqual(seen.count, AbloxInbox.keptSeen)
        XCTAssertEqual(seen.last, "n499", "the newest are kept")
    }

    func testEachNewOneIsSentToTheIPadOnce() {
        let items = AbloxInbox.items(sources(), language: .english)
        let first = AbloxInbox.toPost(items, seen: [], posted: [])
        XCTAssertEqual(first.count, items.count)
        XCTAssertTrue(AbloxInbox.toPost(items, seen: [], posted: Set(first.map(\.id))).isEmpty)
        XCTAssertTrue(AbloxInbox.toPost(items, seen: Set(items.map(\.id)), posted: []).isEmpty, "already seen in the list")
    }
}
