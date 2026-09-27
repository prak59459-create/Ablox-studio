import Foundation

// Playing and keeping in touch over the internet, through a Firebase
// Realtime Database that the family (or whoever builds Ablox) sets up.
//
// Ablox talks to it with nothing but HTTPS — Firebase's REST interface and
// its streaming ("server-sent events") — so there is no SDK to add and it
// works in Swift Playgrounds. Everything here is plain data and parsing, so
// it is tested off the iPad; `Net/Cloud*.swift` does the talking.
//
// What goes up, and who can read it, is decided by the rules in
// `CloudRules.json` (shown in Settings and in docs/firebase_*.md):
//
// - A game in progress is never readable by Firebase: the iPads' own
//   encrypted stream (TLS with the room code) is passed through it in pieces.
// - A player's profile — name, look, the game they are in — only by friends
//   who have added each other.
// - Chat only by the two friends in it.
// - The list of internet rooms by anyone signed in to that database.

// MARK: - Settings

/// Which database, and the key to sign in to it.
public struct CloudConfig: Codable, Hashable, Sendable {
    public var databaseURL: String
    public var apiKey: String

    public init(databaseURL: String = "", apiKey: String = "") {
        self.databaseURL = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filled in by whoever builds Ablox for their family or class, so the
    /// iPads need nothing typed in (docs/firebase_*.md, step 4). Empty: each
    /// iPad enters it in Settings → Family → Internet.
    public static let builtIn = CloudConfig(databaseURL: "https://ablox-ee138-default-rtdb.asia-southeast1.firebasedatabase.app",
                                            apiKey: "AIzaSyCPUcRIkBS69RJf38uPoO5YZMC4RxjXmpc")

    /// The database's address with nothing after it — only a Firebase
    /// Realtime Database, so the key is never sent anywhere else.
    public var baseURL: URL? {
        var text = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              host.hasSuffix(".firebaseio.com") || host.hasSuffix(".firebasedatabase.app"),
              url.path.isEmpty || url.path == "/", url.query == nil, url.user == nil else { return nil }
        return url
    }

    public var isUsable: Bool {
        let key = trimmedKey
        return baseURL != nil && (20...80).contains(key.count)
            && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && key.unicodeScalars.allSatisfy(\.isASCII)
    }

    public var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Where things live

public enum CloudPath {
    public static func profile(_ uid: String) -> String { "users/\(uid)/profile" }
    public static func friendCode(_ code: String) -> String { "codes/\(code)" }
    public static func requests(to uid: String) -> String { "requests/\(uid)" }
    public static func request(to uid: String, from sender: String) -> String { "requests/\(uid)/\(sender)" }
    public static func friends(of uid: String) -> String { "friends/\(uid)" }
    public static func friend(of uid: String, _ other: String) -> String { "friends/\(uid)/\(other)" }
    public static func chat(_ pair: String) -> String { "chats/\(pair)" }
    public static let lobby = "lobby"
    public static func room(_ key: String) -> String { "lobby/\(key)" }
    public static func relay(_ key: String) -> String { "relay/\(key)" }
    public static func link(_ key: String, _ link: String) -> String { "relay/\(key)/links/\(link)" }
    public static func up(_ key: String) -> String { "relay/\(key)/up" }
    public static func up(_ key: String, _ link: String) -> String { "relay/\(key)/up/\(link)" }
    public static func down(_ key: String, _ link: String) -> String { "relay/\(key)/down/\(link)" }

    /// Safe as one step of a path: Firebase refuses `. $ # [ ] /`, and
    /// anything that came from another iPad is checked before it is used.
    public static func isSafeKey(_ key: String) -> Bool {
        (1...64).contains(key.count) && key.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }
}

public enum CloudIDs {
    /// One chat between two people, the same whichever of them asks.
    public static func pair(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    /// The other person in a chat.
    public static func other(in pair: String, than uid: String) -> String? {
        let parts = pair.split(separator: "_").map(String.init)
        guard parts.count == 2, parts.contains(uid) else { return nil }
        return parts[0] == uid ? parts[1] : parts[0]
    }

    /// Letters and numbers that cannot be mistaken for each other.
    public static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// A friend code: eight characters, shown as ABCD-2345.
    public static func newFriendCode<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<8).map { _ in codeAlphabet[Int.random(in: 0..<codeAlphabet.count, using: &generator)] })
    }

    public static func newFriendCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return newFriendCode(using: &generator)
    }

    /// What was typed, as the code it is: capitals, no dashes or spaces.
    public static func normalizeFriendCode(_ text: String) -> String? {
        // No O, 0, I or 1 in a code: they are too easily mixed up to use.
        let code = String(text.uppercased().filter { !$0.isWhitespace && $0 != "-" })
        guard code.count == 8, code.allSatisfy({ codeAlphabet.contains($0) }) else { return nil }
        return code
    }

    public static func displayFriendCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return String(code.prefix(4)) + "-" + String(code.suffix(4))
    }

    /// A random key for a relay link.
    public static func newLinkID() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<20).map { _ in letters.randomElement()! })
    }

    /// Chunk numbers as keys that sort the way the numbers do.
    public static func sequenceKey(_ number: Int) -> String {
        let digits = String(Swift.max(0, number))
        return String(repeating: "0", count: Swift.max(0, 10 - digits.count)) + digits
    }
}

// MARK: - What is kept there

/// What friends see of a player: their name and look, whether they are on,
/// and what they are playing.
public struct CloudProfile: Codable, Hashable, Sendable {
    public var avatar: AvatarProfile
    /// Their friend code, so a friend can show it to someone else.
    public var code: String
    public var online: Bool
    /// When they were last seen, in milliseconds since 1970 (the server's).
    public var seen: Double
    /// The game they are in, if any.
    public var game: String?
    /// The internet room they are in, which friends can join.
    public var room: String?

    public init(avatar: AvatarProfile, code: String, online: Bool, seen: Double = 0, game: String? = nil, room: String? = nil) {
        self.avatar = avatar
        self.code = code
        self.online = online
        self.seen = seen
        self.game = game
        self.room = room
    }

    /// Made safe to show, whatever was written.
    public var cleaned: CloudProfile {
        var copy = self
        copy.avatar = avatar.sanitizedForNetwork()
        copy.game = game.map { String(ChatModerator().cleanName(String($0.prefix(60)))) }
        copy.room = room.flatMap { CloudPath.isSafeKey($0) ? $0 : nil }
        copy.code = CloudIDs.normalizeFriendCode(code) ?? ""
        if !seen.isFinite { copy.seen = 0 }
        return copy
    }

    /// On, and heard from in the last few minutes (an iPad that went flat
    /// never gets to say it is leaving).
    public func isOnline(now: Double) -> Bool {
        let fiveMinutes: Double = 300_000
        return online && now - seen < fiveMinutes
    }
}

public struct CloudFriendRequest: Codable, Hashable, Sendable {
    public var name: String
    public var at: Double

    public init(name: String, at: Double = 0) {
        self.name = name
        self.at = at
    }
}

public struct CloudMessage: Codable, Hashable, Sendable, Identifiable {
    public static let maximumLength = 200
    /// Kept per chat; older lines are removed by whoever sends.
    public static let keptMessages = 60

    /// The database's key for it, which sorts in the order sent.
    public var id: String = ""
    public var from: String
    public var text: String
    public var at: Double

    private enum CodingKeys: String, CodingKey { case from, text, at }

    public init(id: String = "", from: String, text: String, at: Double = 0) {
        self.id = id
        self.from = from
        self.text = String(text.prefix(Self.maximumLength))
        self.at = at
    }
}

/// An internet room, as the list of rooms shows it.
public struct CloudRoom: Codable, Hashable, Sendable, Identifiable {
    /// A room not heard from for this long is gone.
    public static let staleAfter: Double = 2 * 60_000

    public var id: String = ""
    public var host: String
    public var hostName: String
    public var world: String
    public var worldID: String
    public var players: Int
    public var capacity: Int
    public var protocolVersion: Int
    /// The room code and key salt: everyone who can see the room may join
    /// it, so they are in the list, as they are on the router.
    public var code: String
    public var salt: String
    public var at: Double

    private enum CodingKeys: String, CodingKey {
        case host, hostName, world, worldID, players, capacity, protocolVersion = "protocol", code, salt, at
    }

    public init(id: String = "", host: String, hostName: String, world: String, worldID: String, players: Int, capacity: Int,
                protocolVersion: Int = AbloxProtocol.version, code: String, salt: String, at: Double = 0) {
        self.id = id
        self.host = host
        self.hostName = String(hostName.prefix(40))
        self.world = String(world.prefix(60))
        self.worldID = worldID
        self.players = players
        self.capacity = capacity
        self.protocolVersion = protocolVersion
        self.code = code
        self.salt = salt
        self.at = at
    }

    public func isFresh(now: Double) -> Bool { now - at < Self.staleAfter }
    public var isFull: Bool { players >= capacity }
    public var isCompatible: Bool { protocolVersion == AbloxProtocol.version }

    /// What joining needs, pointed at this iPad's end of the relay.
    public func ticket(localPort: UInt16) -> JoinTicket? {
        JoinTicket(host: "127.0.0.1", port: localPort, salt: salt, code: code, world: world)
    }
}

// MARK: - JSON as Firebase sends it

/// A JSON value, for the parts of a stream whose shape depends on where in
/// the tree the change was.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let value as String: self = .string(value)
        case let value as NSNumber:
            // JSONSerialization's true and false arrive as numbers too; their
            // type is "c".
            if String(cString: value.objCType) == "c" { self = .bool(value.boolValue) } else { self = .number(value.doubleValue) }
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .number(Double(value))
        case let value as Double: self = .number(value)
        case let value as [Any]: self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    public init(data: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(\.any)
        case let .object(values): return values.mapValues(\.any)
        }
    }

    public var data: Data {
        (try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8)
    }

    public var object: [String: JSONValue]? {
        if case let .object(values) = self { return values }
        // Firebase sends a map with keys 0, 1, 2… as an array.
        if case let .array(values) = self {
            var map: [String: JSONValue] = [:]
            for (index, value) in values.enumerated() where value != .null { map[String(index)] = value }
            return map
        }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue {
        object?[key] ?? .null
    }

    /// Decodes a Codable value from this part of the tree.
    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    /// Writes `value` at `path` (steps separated by "/"), as Firebase does
    /// for a `put`: null removes.
    public func setting(_ path: [String], to value: JSONValue) -> JSONValue {
        guard let first = path.first else { return value }
        var map = object ?? [:]
        let child = (map[first] ?? .null).setting(Array(path.dropFirst()), to: value)
        if child == .null { map.removeValue(forKey: first) } else { map[first] = child }
        return map.isEmpty ? .null : .object(map)
    }

    /// Merges `value`'s children in at `path`, as Firebase does for a `patch`.
    public func patching(_ path: [String], with value: JSONValue) -> JSONValue {
        var result = self
        for (key, child) in value.object ?? [:] {
            result = result.setting(path + [key], to: child)
        }
        return result
    }
}

// MARK: - The stream

/// One change from a streamed location.
public struct CloudEvent: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case put, patch
        case keepAlive = "keep-alive"
        case cancel
        case authRevoked = "auth_revoked"
    }

    public var kind: Kind
    public var path: [String]
    public var data: JSONValue
}

/// Reads Firebase's event stream a line at a time.
public struct CloudEventParser: Sendable {
    private var event: String?
    private var dataLines: [String] = []

    public init() {}

    /// A line without its newline. Returns an event when a blank line ends one.
    public mutating func feed(_ line: String) -> CloudEvent? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.isEmpty {
            defer { event = nil; dataLines = [] }
            guard let name = event, let kind = CloudEvent.Kind(rawValue: name) else { return nil }
            let body = dataLines.joined(separator: "\n")
            switch kind {
            case .put, .patch:
                guard let parsed = try? JSONValue(data: Data(body.utf8)) else { return nil }
                let path = (parsed["path"].string ?? "/").split(separator: "/").map(String.init)
                return CloudEvent(kind: kind, path: path, data: parsed["data"])
            case .keepAlive, .cancel, .authRevoked:
                return CloudEvent(kind: kind, path: [], data: .null)
            }
        }
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// A copy of a streamed location, kept up to date by its events.
public struct CloudMirror: Sendable {
    public private(set) var value: JSONValue = .null

    public init() {}

    public mutating func apply(_ event: CloudEvent) {
        switch event.kind {
        case .put: value = value.setting(event.path, to: event.data)
        case .patch: value = value.patching(event.path, with: event.data)
        case .keepAlive, .cancel, .authRevoked: break
        }
    }
}

// MARK: - A stream of bytes, in numbered pieces

/// What one side of a relay link has to send: bytes gathered while the
/// last piece was on its way, sent as the next numbered piece.
public struct RelayOutbox: Sendable {
    /// Firebase takes up to 10 MB a write; a quarter of a megabyte keeps
    /// each one quick.
    public static let maximumChunk = 256 * 1024

    public private(set) var nextSequence = 0
    private var pending = Data()

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    public mutating func append(_ bytes: Data) {
        pending.append(bytes)
    }

    /// The next piece to send, numbered.
    public mutating func take() -> (key: String, base64: String)? {
        guard !pending.isEmpty else { return nil }
        let piece = pending.prefix(Self.maximumChunk)
        pending = Data(pending.dropFirst(piece.count))
        let key = CloudIDs.sequenceKey(nextSequence)
        nextSequence += 1
        return (key, Data(piece).base64EncodedString())
    }
}

/// The other side: numbered pieces as they arrive, in whatever order,
/// handed on in order.
public struct RelayInbox: Sendable {
    public private(set) var nextSequence = 0
    private var waiting: [Int: Data] = [:]
    /// Keys handed on, for deleting from the database.
    public private(set) var consumed: [String] = []

    public init() {}

    /// Everything under the link (key → base64), however much of it is new.
    public mutating func receive(_ pieces: [String: JSONValue]) -> Data {
        for (key, value) in pieces {
            guard let number = Int(key), number >= nextSequence, waiting[number] == nil,
                  let text = value.string, let bytes = Data(base64Encoded: text) else { continue }
            waiting[number] = bytes
        }
        var ready = Data()
        while let bytes = waiting.removeValue(forKey: nextSequence) {
            ready.append(bytes)
            consumed.append(CloudIDs.sequenceKey(nextSequence))
            nextSequence += 1
        }
        return ready
    }

    /// Keys to delete now; forgets them.
    public mutating func takeConsumed() -> [String] {
        defer { consumed = [] }
        return consumed
    }
}

// MARK: - This iPad's choices

/// What a grown-up has allowed over the internet (Settings → Family →
/// Internet). Everything starts off.
public struct CloudSettings: Codable, Hashable, Sendable {
    /// Internet rooms: hosting one, and seeing and joining others'.
    public var allowInternetPlay = false
    /// Friends over the internet, and chatting with them.
    public var allowFriends = false
    public var allowFriendChat = false
    /// Friends see which game this iPad is in.
    public var shareWhatIPlay = true
    /// A database typed in here, instead of the one built into the app.
    public var custom = CloudConfig()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudSettings()
        allowInternetPlay = (try? c.decodeIfPresent(Bool.self, forKey: .allowInternetPlay)) ?? d.allowInternetPlay
        allowFriends = (try? c.decodeIfPresent(Bool.self, forKey: .allowFriends)) ?? d.allowFriends
        allowFriendChat = (try? c.decodeIfPresent(Bool.self, forKey: .allowFriendChat)) ?? d.allowFriendChat
        shareWhatIPlay = (try? c.decodeIfPresent(Bool.self, forKey: .shareWhatIPlay)) ?? d.shareWhatIPlay
        custom = (try? c.decodeIfPresent(CloudConfig.self, forKey: .custom)) ?? d.custom
    }

    /// The database to use: one typed in here, or the app's own.
    public var config: CloudConfig {
        custom.isUsable ? custom : CloudConfig.builtIn
    }

    /// Anything switched on, with somewhere to connect to.
    public var isActive: Bool {
        config.isUsable && (allowInternetPlay || allowFriends)
    }
}

extension JSONValue {
    /// Firebase fills this in with its own clock when it is written.
    public static let serverTime = JSONValue.object([".sv": .string("timestamp")])

    /// A Codable value as JSON, for writing.
    public static func encoding<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONValue(data: data)
    }

    /// The same object with `key` set.
    public func with(_ key: String, _ value: JSONValue) -> JSONValue {
        var map = object ?? [:]
        map[key] = value
        return .object(map)
    }
}

// MARK: - Who can join a room

/// The three kinds of room: on the internet for anyone with Ablox (and on
/// the router too), in the list on the router, or on the router for people
/// with the code.
public enum RoomAccess: String, Codable, CaseIterable, Sendable {
    case internet
    case routerPublic
    case routerPrivate

    /// Whether the room's code is in the router's list.
    public var isPublicOnRouter: Bool { self != .routerPrivate }

    public var displayName: String {
        switch self {
        case .internet: return L("Internet — anyone with Ablox can join")
        case .routerPublic: return L("Router, public — anyone on this Wi-Fi can join")
        case .routerPrivate: return L("Router, private — only people with the room code")
        }
    }

    public var symbolName: String {
        switch self {
        case .internet: return "globe"
        case .routerPublic: return "wifi"
        case .routerPrivate: return "lock.fill"
        }
    }
}
