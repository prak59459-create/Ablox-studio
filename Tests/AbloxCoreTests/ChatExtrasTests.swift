import XCTest
@testable import AbloxCore

/// Chat and friends, the second round.
final class ChatExtrasTests: XCTestCase {

    func testPhraseGroupsAreFullAndTranslated() {
        for group in QuickChatGroup.allCases {
            XCTAssertGreaterThanOrEqual(group.phrases.count, 6, "\(group)")
            XCTAssertEqual(Set(group.phrases).count, group.phrases.count)
            for phrase in group.phrases {
                XCTAssertLessThanOrEqual(phrase.count, AbloxProtocol.maxChatLength)
                XCTAssertFalse(ChatModerator().filter(phrase).wasFiltered, phrase)
                // Sent as the player's language shows it, so it must be in the catalogue.
                XCTAssertNotNil(Strings.japanese[phrase], "\(phrase) has no Japanese")
            }
        }
        XCTAssertGreaterThanOrEqual(QuickChatGroup.allPhrases.count, 40)
        // Everything the old single row had is still there.
        XCTAssertTrue(Set(QuickChatGroup.allPhrases).isSuperset(of: QuickChat.phrases))
    }

    func testSavedPhrasesRefuseWhatTheFilterOrPrivacyWouldHide() throws {
        var saved = SavedPhrases()
        XCTAssertEqual(saved.add("  Meet me at the castle!  "), .added)
        XCTAssertEqual(saved.phrases, ["Meet me at the castle!"])
        XCTAssertEqual(saved.add("meet me at the castle!"), .duplicate)
        XCTAssertEqual(saved.add("   "), .empty)
        XCTAssertEqual(saved.add("you are stupid"), .notAllowed)
        XCTAssertEqual(saved.add("call 090 1234 5678"), .notAllowed)
        for n in 1..<SavedPhrases.maximum { _ = saved.add("Phrase \(n)") }
        XCTAssertEqual(saved.phrases.count, SavedPhrases.maximum)
        XCTAssertEqual(saved.add("one too many"), .full)
        saved.move(from: 0, to: 3)
        XCTAssertEqual(saved.phrases[2], "Meet me at the castle!")
        let back = try JSONDecoder().decode(SavedPhrases.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back, saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedPhrases.self, from: Data("{}".utf8)), SavedPhrases())
    }

    func testSentHistoryIsNewestFirstWithoutRepeats() {
        var history = SentHistory()
        history.said("hi")
        history.said("go")
        history.said("hi")
        XCTAssertEqual(history.lines, ["hi", "go"])
        for n in 0..<20 { history.said("line \(n)") }
        XCTAssertEqual(history.lines.count, SentHistory.kept)
        XCTAssertEqual(history.lines.first, "line 19")
    }

    func testTheFloodGuard() {
        var limiter = ChatRateLimiter()
        XCTAssertEqual(limiter.allow("hi", at: 0), .ok)
        XCTAssertEqual(limiter.allow("HI ", at: 1), .repeated)
        XCTAssertEqual(limiter.allow("hi", at: 6), .ok, "the same again after a pause")
        XCTAssertEqual(limiter.allow("a", at: 7), .ok)
        XCTAssertEqual(limiter.allow("b", at: 7.5), .ok)
        XCTAssertEqual(limiter.allow("c", at: 8), .ok)
        guard case let .tooFast(seconds) = limiter.allow("d", at: 8.5) else { return XCTFail("five in ten seconds is the most") }
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertEqual(limiter.allow("d", at: 16.5), .ok)
    }

    func testPersonalDetailsAreHidden() {
        XCTAssertEqual(ChatTidy.personalInfoHidden("call me 090-1234-5678 ok"), "call me ••• ok")
        XCTAssertEqual(ChatTidy.personalInfoHidden("０９０１２３４５６７８"), "•••")
        XCTAssertEqual(ChatTidy.personalInfoHidden("mail kai@example.com"), "mail •••")
        XCTAssertEqual(ChatTidy.personalInfoHidden("see https://example.com/x now"), "see ••• now")
        XCTAssertEqual(ChatTidy.personalInfoHidden("go to youtube.com"), "go to •••")
        // Scores and times stay.
        XCTAssertEqual(ChatTidy.personalInfoHidden("I got 125000 points in 3:45"), "I got 125000 points in 3:45")
        XCTAssertEqual(ChatTidy.personalInfoHidden("room 12, level 7"), "room 12, level 7")
    }

    func testShoutingRepeatsAndMentions() {
        XCTAssertEqual(ChatTidy.shoutingSoftened("COME HERE EVERYONE"), "Come here everyone")
        XCTAssertEqual(ChatTidy.shoutingSoftened("OK GG"), "OK GG", "short is fine")
        XCTAssertEqual(ChatTidy.shoutingSoftened("すごい WOW"), "すごい WOW")
        XCTAssertEqual(ChatTidy.repeatsSquashed("hiiiiiiii!!!!!!"), "hiii!!!")
        XCTAssertEqual(ChatTidy.repeatsSquashed("wwwwwww"), "www")
        XCTAssertEqual(ChatTidy.repeatsSquashed("book"), "book")
        XCTAssertTrue(ChatTidy.mentions("Kai", in: "hey kai, over here"))
        XCTAssertTrue(ChatTidy.mentions("Kai", in: "@Kai!"))
        XCTAssertFalse(ChatTidy.mentions("Kai", in: "kaiju attack"))
        XCTAssertFalse(ChatTidy.mentions("K", in: "k"))
        var options = ChatOptions()
        options.softenShouting = false
        XCTAssertEqual(ChatTidy.tidy("CALL 09012345678 NOWWWWWW", options: options), "CALL ••• NOWWW")
    }

    func testChatOptionsLoadTolerantlyAndDecideNamesAndBubbles() throws {
        var preferences = PlayPreferences()
        preferences.chat.nameTags = .friends
        preferences.chat.bubbleTime = .long
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(PlayPreferences.self, from: data), preferences)
        let odd = try JSONDecoder().decode(PlayPreferences.self, from: Data(#"{"chat":{"lines":99,"nameTags":"aliens","readAloud":true}}"#.utf8))
        XCTAssertEqual(odd.chat.lines, 5)
        XCTAssertEqual(odd.chat.nameTags, .everyone)
        XCTAssertTrue(odd.chat.readAloud)
        XCTAssertTrue(preferences.chat.showsName(isFriend: true))
        XCTAssertFalse(preferences.chat.showsName(isFriend: false))
        XCTAssertEqual(preferences.chat.bubbleAge(14), 8, accuracy: 0.001, "a long bubble reaches the end at 14 seconds")
        XCTAssertEqual(ChatOptions().bubbleAge(3), 3)
    }

    func testStrictAndFamilyWords() {
        XCTAssertEqual(ChatModerator().filter("what a noob").text, "what a noob")
        XCTAssertEqual(ChatModerator(strict: true).filter("what a noob").text, "what a ****")
        XCTAssertEqual(ChatModerator(strict: true).filter("やくそくだよ").text, "やくそくだよ", "a promise is not rude")
        var parental = ParentalControls()
        XCTAssertTrue(parental.addBlockedWord(" Banana "))
        XCTAssertFalse(parental.addBlockedWord("banana"))
        XCTAssertFalse(parental.addBlockedWord(""))
        let moderator = ChatModerator(additionalTerms: parental.extraBlockedWords ?? [])
        XCTAssertEqual(moderator.filter("I like banana").text, "I like ******")
        parental.removeBlockedWord("banana")
        XCTAssertNil(parental.extraBlockedWords)
    }

    func testFriendsSortGroupSearchAndPins() throws {
        var book = SocialBook()
        let a = PeerID(), b = PeerID(), c = PeerID()
        let start = Date(timeIntervalSince1970: 1_000_000)
        book.addFriend(a, name: "Aoi", at: start)
        book.addFriend(b, name: "Ben", at: start)
        book.addFriend(c, name: "Chika", at: start)
        XCTAssertEqual(book.friends.first?.friendSince, start)
        book.setGroup(.school, for: b)
        book.setNote("sits next to me", for: c)
        book.setFavourite(true, for: c)
        XCTAssertEqual(book.friends(sortedBy: .name).map(\.name), ["Chika", "Aoi", "Ben"], "pinned first")
        XCTAssertEqual(book.friends(sortedBy: .name, group: .school).map(\.name), ["Ben"])
        XCTAssertEqual(book.friends(sortedBy: .name, search: "next to").map(\.name), ["Chika"])
        book.setFavourite(false, for: c)
        XCTAssertEqual(book.friends(sortedBy: .name).map(\.name), ["Aoi", "Ben", "Chika"])
        book.setNote("", for: c)
        XCTAssertNil(book.friends.first { $0.id == c }?.note)

        // Old saves, and a group from a newer version, still load.
        let data = try JSONEncoder().encode(book)
        XCTAssertEqual(try JSONDecoder().decode(SocialBook.self, from: data), book)
        var json = String(decoding: data, as: UTF8.self)
        json = json.replacingOccurrences(of: "\"school\"", with: "\"spaceship\"")
        let newer = try JSONDecoder().decode(SocialBook.self, from: Data(json.utf8))
        XCTAssertEqual(newer.friends.count, 3)
        XCTAssertNil(newer.friends.first { $0.id == b }?.group)
    }
}
