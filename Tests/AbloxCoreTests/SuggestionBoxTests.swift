import XCTest
@testable import AbloxCore

final class SuggestionBoxTests: XCTestCase {

    func testWordsAreTidiedBeforeTheyLeave() {
        let words = SuggestionBox.tidied("  もっと車のゲームがほしい！ call me 090-1234-5678 or mika@example.com  ")
        XCTAssertFalse(words.contains("090-1234-5678"))
        XCTAssertFalse(words.contains("mika@example.com"))
        XCTAssertTrue(words.hasPrefix("もっと車のゲームがほしい！"))
        XCTAssertEqual(SuggestionBox.tidied(String(repeating: "あ", count: 900)).count, SuggestionBox.longest)
    }

    func testTooShortOrTooSoonIsSaidKindly() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNotNil(SuggestionBox.problem(with: " hi ", lastSent: nil, now: now))
        XCTAssertNil(SuggestionBox.problem(with: "A racing game with boats", lastSent: nil, now: now))
        XCTAssertNotNil(SuggestionBox.problem(with: "A racing game with boats", lastSent: now.addingTimeInterval(-20), now: now))
        XCTAssertNil(SuggestionBox.problem(with: "A racing game with boats", lastSent: now.addingTimeInterval(-61), now: now))
    }

    func testIDsSortByTimeAndMatchTheRules() {
        let first = SuggestionBox.newID(now: Date(timeIntervalSince1970: 1_700_000_000))
        let second = SuggestionBox.newID(now: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertLessThan(first, second)
        XCTAssertNotNil(first.range(of: #"^s[0-9]{10,16}-[A-Z2-9]{6}$"#, options: .regularExpression))
        XCTAssertTrue(CloudPath.isSafeKey(first))
    }

    func testTheWriteSendsOnlyWhatTheRulesAllow() throws {
        let write = SuggestionBox.write(id: "s1700000000000-ABCDEF", uid: "u1", kind: .game,
                                        text: "A game about trains, mail me at a@b.co", app: "Ablox", version: "1.8", language: "ja")
        XCTAssertEqual(Set(write.keys), ["suggestions/s1700000000000-ABCDEF", "suggestionTimes/u1"])
        let body = try XCTUnwrap(write["suggestions/s1700000000000-ABCDEF"]?.object)
        XCTAssertEqual(Set(body.keys), ["from", "kind", "text", "app", "version", "language", "at"])
        XCTAssertEqual(body["from"], .string("u1"))
        XCTAssertEqual(body["kind"], .string("game"))
        XCTAssertFalse(body["text"]?.string?.contains("a@b.co") ?? true)
        XCTAssertEqual(body["at"], JSONValue.serverTime)
        XCTAssertEqual(write["suggestionTimes/u1"], JSONValue.serverTime)
    }

    func testTheRulesLetOnlyTheReaderRead() throws {
        let rules = try JSONValue(data: Data(CloudRules.json.utf8))["rules"]
        let box = rules["suggestions"]
        XCTAssertEqual(box[".read"].string, "auth != null && auth.uid === '\(SuggestionBox.readerUID)'")
        let write = try XCTUnwrap(box["$id"][".write"].string)
        XCTAssertTrue(write.contains("!data.exists()"), "a suggestion is never changed once sent")
        XCTAssertTrue(write.contains("suggestionTimes"), "one a minute")
        let validate = try XCTUnwrap(box["$id"][".validate"].string)
        XCTAssertTrue(validate.contains("<= \(SuggestionBox.longest)"))
        XCTAssertTrue(validate.contains(">= \(SuggestionBox.shortest)"))
        for kind in SuggestionKind.allCases {
            XCTAssertTrue(validate.contains(kind.rawValue), "\(kind) is refused by the rules")
        }
        XCTAssertTrue(rules["suggestionTimes"]["$uid"][".write"].string?.contains("now - \(Int(SuggestionBox.secondsBetween * 1000))") ?? false)
    }

    func testSentSuggestionsKeepTheNewestThirty() {
        var sent = SentSuggestions()
        for n in 0..<40 {
            sent.add(SentSuggestion(id: "s\(n)", kind: .feature, text: "idea \(n)", sentAt: Date(timeIntervalSince1970: Double(n))))
        }
        XCTAssertEqual(sent.items.count, SentSuggestions.kept)
        XCTAssertEqual(sent.items.first?.id, "s39")
        XCTAssertEqual(sent.lastSent, Date(timeIntervalSince1970: 39))
    }

    func testRepliesAreReadEvenWithABadEntry() throws {
        let json = #"""
        {"replies": [
          {"id": "s1-AAAAAA", "status": "done", "message": {"en": "Added!", "ja": "追加しました！"}, "version": "1.9"},
          {"status": "done"},
          {"id": "s2-BBBBBB", "status": "someday", "message": {"en": "Read"}},
          {"id": "s3-CCCCCC", "status": "planned", "message": {"ja": "作っています"}}
        ]}
        """#
        let replies = try JSONDecoder().decode(SuggestionReplies.self, from: Data(json.utf8))
        XCTAssertEqual(replies.replies.count, 3, "the entry without an id is skipped")
        XCTAssertEqual(replies.reply(for: "s1-AAAAAA")?.message(in: "ja"), "追加しました！")
        XCTAssertEqual(replies.reply(for: "s1-AAAAAA")?.version, "1.9")
        XCTAssertEqual(replies.reply(for: "s2-BBBBBB")?.status, .thanks, "an unknown status reads as thanks")
        XCTAssertEqual(replies.reply(for: "s3-CCCCCC")?.message(in: "en"), "作っています", "any language rather than none")
        XCTAssertNil(replies.reply(for: "nope"))
    }

    func testTheRepliesFileSitsBesideTheUpdate() {
        let url = SuggestionReplies.url(for: UpdateChannel(owner: "prak59459-create", repository: "Ablox"))
        XCTAssertEqual(url?.absoluteString, "https://raw.githubusercontent.com/prak59459-create/Ablox/HEAD/suggestions/replies.json")
    }

    /// The file in the repository reads, and holds nothing but keys and answers.
    func testThePublishedRepliesFileReads() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = root.appendingPathComponent("suggestions/replies.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("The replies live in the Ablox repository.")
        }
        let data = try Data(contentsOf: file)
        _ = try JSONDecoder().decode(SuggestionReplies.self, from: data)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for entry in raw["replies"] as? [[String: Any]] ?? [] {
            XCTAssertTrue(Set(entry.keys).isSubset(of: ["id", "status", "message", "version"]),
                          "a reply carries no suggestion's words: \(entry.keys)")
        }
    }
}
