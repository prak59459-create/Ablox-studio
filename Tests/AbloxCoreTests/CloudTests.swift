import XCTest
@testable import AbloxCore

/// The internet parts that are plain data: settings, paths, codes, JSON as
/// Firebase sends it, its event stream, the relay's numbered pieces and the
/// database rules.
final class CloudTests: XCTestCase {

    // MARK: Settings

    func testOnlyAFirebaseDatabaseIsAccepted() {
        XCTAssertTrue(CloudConfig(databaseURL: "https://ablox-kids-default-rtdb.asia-southeast1.firebasedatabase.app/",
                                  apiKey: "AIzaSyA1234567890abcdefghijklmnopqrstu").isUsable)
        XCTAssertTrue(CloudConfig(databaseURL: "https://ablox-kids.firebaseio.com", apiKey: "AIzaSyA1234567890abcdefghij").isUsable)
        XCTAssertFalse(CloudConfig(databaseURL: "http://ablox.firebaseio.com", apiKey: "AIzaSyA1234567890abcdefghij").isUsable,
                       "never without encryption")
        XCTAssertFalse(CloudConfig(databaseURL: "https://example.com", apiKey: "AIzaSyA1234567890abcdefghij").isUsable,
                       "the key is never sent anywhere but Firebase")
        XCTAssertFalse(CloudConfig(databaseURL: "https://a.firebaseio.com/users", apiKey: "AIzaSyA1234567890abcdefghij").isUsable)
        XCTAssertFalse(CloudConfig(databaseURL: "https://a.firebaseio.com", apiKey: "short").isUsable)
        XCTAssertFalse(CloudConfig(databaseURL: "https://a.firebaseio.com", apiKey: "AIzaSyA1234567890abc/efghij").isUsable)
    }

    func testInternetThingsStartOff() throws {
        let fresh = CloudSettings()
        XCTAssertFalse(fresh.allowInternetPlay)
        XCTAssertFalse(fresh.allowFriends)
        XCTAssertFalse(fresh.allowFriendChat)
        XCTAssertFalse(fresh.isActive)

        let old = try JSONDecoder().decode(CloudSettings.self, from: Data(#"{"allowFriends":true}"#.utf8))
        XCTAssertTrue(old.allowFriends)
        XCTAssertTrue(old.shareWhatIPlay, "a setting added later takes its default")
    }

    func testTheThreeKindsOfRoom() {
        XCTAssertTrue(RoomAccess.internet.isPublicOnRouter)
        XCTAssertTrue(RoomAccess.routerPublic.isPublicOnRouter)
        XCTAssertFalse(RoomAccess.routerPrivate.isPublicOnRouter)
    }

    // MARK: Codes and paths

    func testFriendCodes() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<50 {
            let code = CloudIDs.newFriendCode(using: &generator)
            XCTAssertEqual(CloudIDs.normalizeFriendCode(code), code)
            XCTAssertTrue(CloudPath.isSafeKey(code))
        }
        XCTAssertEqual(CloudIDs.normalizeFriendCode(" abcd-2345 "), "ABCD2345")
        XCTAssertNil(CloudIDs.normalizeFriendCode("ABCD-234O"), "no O, 0, I or 1 in a code")
        XCTAssertNil(CloudIDs.normalizeFriendCode("ABC"))
        XCTAssertEqual(CloudIDs.displayFriendCode("ABCD2345"), "ABCD-2345")
    }

    func testAChatIsTheSameWhoeverAsks() {
        XCTAssertEqual(CloudIDs.pair("zed", "amy"), CloudIDs.pair("amy", "zed"))
        XCTAssertEqual(CloudIDs.other(in: CloudIDs.pair("zed", "amy"), than: "amy"), "zed")
        XCTAssertNil(CloudIDs.other(in: "a_b", than: "c"))
    }

    func testPathStepsFromOtherIPadsAreChecked() {
        XCTAssertTrue(CloudPath.isSafeKey("Xy12_ab-9"))
        for bad in ["", "a/b", "a.b", "a$b", "a#b", "a[b]", String(repeating: "a", count: 65), "ü"] {
            XCTAssertFalse(CloudPath.isSafeKey(bad), bad)
        }
    }

    func testPieceNumbersSortAsNumbers() {
        let keys = [0, 9, 10, 100, 12345].map(CloudIDs.sequenceKey)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(CloudIDs.sequenceKey(42), "0000000042")
    }

    // MARK: JSON

    func testTrueIsNotOne() throws {
        let value = try JSONValue(data: Data(#"{"on":true,"n":1,"x":2.5,"s":"hi","none":null}"#.utf8))
        XCTAssertEqual(value["on"], .bool(true))
        XCTAssertEqual(value["n"], .number(1))
        XCTAssertEqual(value["x"], .number(2.5))
        XCTAssertEqual(value["s"], .string("hi"))
        XCTAssertEqual(value["none"], .null)
    }

    func testPutAndPatchWorkLikeFirebase() {
        var tree = JSONValue.null
        tree = tree.setting(["a", "b"], to: .number(1))
        tree = tree.setting(["a", "c"], to: .number(2))
        XCTAssertEqual(tree["a"]["b"], .number(1))
        tree = tree.patching(["a"], with: .object(["b": .null, "d": .string("x")]))
        XCTAssertEqual(tree["a"]["b"], .null)
        XCTAssertEqual(tree["a"]["d"], .string("x"))
        tree = tree.setting(["a"], to: .null)
        XCTAssertEqual(tree, .null, "an empty parent goes too")
        XCTAssertEqual(JSONValue.array([.number(5), .null, .number(7)]).object?["2"], .number(7))
    }

    // MARK: The stream

    func testEventsAreReadFromTheStream() {
        var parser = CloudEventParser()
        var events: [CloudEvent] = []
        let text = """
        event: put
        data: {"path":"/","data":{"a":1}}

        event: keep-alive
        data: null

        event: patch
        data: {"path":"/b","data":{"c":"d"}}

        """
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = parser.feed(String(line)) { events.append(event) }
        }
        XCTAssertEqual(events.map(\.kind), [.put, .keepAlive, .patch])
        XCTAssertEqual(events[2].path, ["b"])

        var mirror = CloudMirror()
        events.forEach { mirror.apply($0) }
        XCTAssertEqual(mirror.value["a"], .number(1))
        XCTAssertEqual(mirror.value["b"]["c"], .string("d"))
        mirror.apply(CloudEvent(kind: .put, path: ["a"], data: .null))
        XCTAssertEqual(mirror.value["a"], .null)
    }

    // MARK: The relay

    func testPiecesArriveInOrderWhateverOrderTheyCome() {
        var outbox = RelayOutbox()
        let message = Data((0..<600_000).map { UInt8($0 % 251) })
        outbox.append(message)
        var pieces: [(String, String)] = []
        while let piece = outbox.take() { pieces.append((piece.key, piece.base64)) }
        XCTAssertEqual(pieces.count, 3, "split into quarter-megabyte pieces")

        var inbox = RelayInbox()
        var received = Data()
        // The last piece first, then all of them again (a mirror resends
        // everything it holds), then a duplicate.
        received.append(inbox.receive([pieces[2].0: .string(pieces[2].1)]))
        XCTAssertTrue(received.isEmpty, "nothing until the first piece")
        var all: [String: JSONValue] = [:]
        for (key, text) in pieces { all[key] = .string(text) }
        received.append(inbox.receive(all))
        received.append(inbox.receive(all))
        XCTAssertEqual(received, message)
        XCTAssertEqual(inbox.takeConsumed().count, 3)
        XCTAssertTrue(inbox.takeConsumed().isEmpty)
    }

    func testGarbageInTheRelayIsIgnored() {
        var inbox = RelayInbox()
        XCTAssertTrue(inbox.receive(["0000000000": .number(5), "x": .string("AAAA"), "0000000001": .string("!!!")]).isEmpty)
    }

    // MARK: What friends and rooms look like

    func testAFriendsProfileIsCleanedAndCanGoStale() {
        var avatar = AvatarProfile.default
        avatar.displayName = String(repeating: "N", count: 80)
        let profile = CloudProfile(avatar: avatar, code: "abcd2345", online: true, seen: 1_000_000, game: "Obby", room: "bad/room")
        let clean = profile.cleaned
        XCTAssertLessThanOrEqual(clean.avatar.displayName.count, AvatarProfile.maximumNameLength)
        XCTAssertNil(clean.room)
        XCTAssertEqual(clean.code, "ABCD2345")
        XCTAssertTrue(clean.isOnline(now: 1_000_000 + 60_000))
        XCTAssertFalse(clean.isOnline(now: 1_000_000 + 10 * 60_000))
    }

    func testARoomIsJoinedThroughThisIPad() throws {
        let room = CloudRoom(id: "k", host: "h", hostName: "Mika", world: "Obby", worldID: "w", players: 2, capacity: 8,
                             code: "ABC234", salt: "0123456789abcdef", at: 5_000)
        let ticket = try XCTUnwrap(room.ticket(localPort: 50_123))
        XCTAssertEqual(ticket.host, "127.0.0.1")
        XCTAssertEqual(ticket.port, 50_123)
        XCTAssertTrue(room.isFresh(now: 5_000 + 60_000))
        XCTAssertFalse(room.isFresh(now: 5_000 + CloudRoom.staleAfter + 1))
        let decoded = try XCTUnwrap(JSONValue.encoding(room)?.decode(CloudRoom.self))
        XCTAssertEqual(decoded.protocolVersion, AbloxProtocol.version)
        XCTAssertEqual(JSONValue.encoding(room)?["protocol"], .number(Double(AbloxProtocol.version)))
    }

    func testGuestsThroughTheRelayAreNeverLockedOut() {
        var limiter = AttemptLimiter()
        for _ in 0..<50 { limiter.recordFailure("127.0.0.1", at: 1) }
        XCTAssertFalse(limiter.isBanned("127.0.0.1", at: 2))
        for _ in 0..<50 { limiter.recordFailure("192.168.1.9", at: 1) }
        XCTAssertTrue(limiter.isBanned("192.168.1.9", at: 2))
    }

    // MARK: The rules

    func testTheGuideShowsTheSameRules() throws {
        // docs/firebase_<date>_<time>.md: the file name carries when it was
        // last updated, so it is found by its start.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // The guide is the app's; Studio runs these tests from its own copy.
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Ablox.swiftpm").path) else {
            throw XCTSkip("The Firebase guide lives in the Ablox repository.")
        }
        let docs = root.appendingPathComponent("docs")
        let names = try FileManager.default.contentsOfDirectory(atPath: docs.path).filter { $0.hasPrefix("firebase_") && $0.hasSuffix(".md") }
        XCTAssertEqual(names.count, 1, "one Firebase guide")
        let guide = try String(contentsOf: docs.appendingPathComponent(try XCTUnwrap(names.first)), encoding: .utf8)
        XCTAssertTrue(guide.contains(CloudRules.json), "the guide's rules differ from CloudRules.json")
    }

    func testTheRulesAreValidAndShutByDefault() throws {
        let rules = try JSONValue(data: Data(CloudRules.json.utf8))["rules"]
        XCTAssertEqual(rules[".read"], .bool(false))
        XCTAssertEqual(rules[".write"], .bool(false))
        for place in ["users", "codes", "requests", "friends", "chats", "lobby", "relay"] {
            XCTAssertNotEqual(rules[place], .null, "\(place) has no rules")
        }
        // Profiles: only the owner writes; friends who added each other read.
        let profile = rules["users"]["$uid"]["profile"]
        XCTAssertEqual(profile[".write"].string, "auth != null && auth.uid === $uid")
        XCTAssertTrue(profile[".read"].string?.contains("friends") ?? false)
        // The game's pieces: never readable by anyone but the two ends.
        XCTAssertTrue(rules["relay"]["$room"]["down"]["$link"][".read"].string?.contains("guest") ?? false)
    }
}

/// A repeatable generator for tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
