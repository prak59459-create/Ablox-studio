import Foundation

// The suggestion box: ideas and problems sent from the app to the family's
// Firebase database (`suggestions/<id>`), read only by the helper that
// looks after Ablox (`SuggestionBox.readerUID`), and answered in the
// repository (`suggestions/replies.json`), which the app reads back to show
// what became of each one sent from this iPad.
//
// What is sent: the kind, the words (phone numbers, emails and links
// hidden first), the app and its version, the language, and when. No name,
// no friend code, nothing about the iPad.

/// What a suggestion is about.
public enum SuggestionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case game
    case feature
    case problem
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .game: return L("An idea for a game")
        case .feature: return L("Something to add or change")
        case .problem: return L("Something is wrong")
        case .other: return L("Something else")
        }
    }

    public var symbolName: String {
        switch self {
        case .game: return "gamecontroller.fill"
        case .feature: return "sparkles"
        case .problem: return "ladybug.fill"
        case .other: return "text.bubble.fill"
        }
    }
}

public enum SuggestionBox {
    /// The only account allowed to read the box: the helper that looks after
    /// Ablox. Written into the database rules (`CloudRules`).
    public static let readerUID = "6ktyBZljv5ZgBUgjjHSzrZqv9aj1"
    public static let shortest = 5
    public static let longest = 500
    /// One suggestion a minute from each iPad; the rules say so too.
    public static let secondsBetween: Double = 60

    /// The words as they will be sent: trimmed, personal details hidden,
    /// cut to the longest allowed.
    public static func tidied(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(ChatTidy.personalInfoHidden(trimmed).prefix(longest))
    }

    /// Why it cannot be sent yet, or nil when it can.
    public static func problem(with text: String, lastSent: Date?, now: Date = Date()) -> String? {
        let words = tidied(text)
        if words.count < shortest { return L("Write a little more first.") }
        if let lastSent, now.timeIntervalSince(lastSent) < secondsBetween {
            let wait = Int((secondsBetween - now.timeIntervalSince(lastSent)).rounded(.up))
            return L("Thank you! You can send another in {} seconds.", wait)
        }
        return nil
    }

    /// A key for a new suggestion: sorts by time, and never the same twice.
    public static func newID(now: Date = Date()) -> String {
        let millis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var generator = SystemRandomNumberGenerator()
        let tail = String((0..<6).map { _ in CloudIDs.codeAlphabet[Int.random(in: 0..<CloudIDs.codeAlphabet.count, using: &generator)] })
        return "s\(millis)-\(tail)"
    }

    /// The one write that sends it: the suggestion itself and this iPad's
    /// "last sent" time, together, so the rules can hold it to one a minute.
    public static func write(id: String, uid: String, kind: SuggestionKind, text: String,
                             app: String, version: String, language: String) -> [String: JSONValue] {
        [
            "suggestions/\(id)": .object([
                "from": .string(uid),
                "kind": .string(kind.rawValue),
                "text": .string(tidied(text)),
                "app": .string(String(app.prefix(20))),
                "version": .string(String(version.prefix(20))),
                "language": .string(String(language.prefix(8))),
                "at": JSONValue.serverTime
            ]),
            "suggestionTimes/\(uid)": JSONValue.serverTime
        ]
    }
}

/// One suggestion sent from this iPad, kept to show what became of it.
public struct SentSuggestion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: SuggestionKind
    public var text: String
    public var sentAt: Date

    public init(id: String, kind: SuggestionKind, text: String, sentAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sentAt = sentAt
    }
}

/// The suggestions sent from here, newest first, at most 30.
public struct SentSuggestions: Codable, Hashable, Sendable {
    public private(set) var items: [SentSuggestion] = []
    public static let kept = 30

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([SentSuggestion].self, forKey: .items)) ?? []
    }

    public var lastSent: Date? { items.first?.sentAt }

    public mutating func add(_ suggestion: SentSuggestion) {
        items.removeAll { $0.id == suggestion.id }
        items.insert(suggestion, at: 0)
        if items.count > Self.kept { items.removeLast(items.count - Self.kept) }
    }
}

/// What became of a suggestion, written in the repository by whoever
/// looked at it. Only the suggestion's key, never its words.
public struct SuggestionReply: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case done
        case planned
        case thanks
        case notNow
    }

    public var id: String
    public var status: Status
    /// By language code ("en", "ja").
    public var message: [String: String]
    /// The version it arrived in, when it is done.
    public var version: String?

    public init(id: String, status: Status, message: [String: String], version: String? = nil) {
        self.id = id
        self.status = status
        self.message = message
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .thanks
        message = (try? c.decodeIfPresent([String: String].self, forKey: .message)) ?? [:]
        version = try? c.decodeIfPresent(String.self, forKey: .version)
    }

    /// The message in `language`, or English, or any.
    public func message(in language: String) -> String? {
        message[language] ?? message["en"] ?? message.values.sorted().first
    }

    public var statusName: String {
        switch status {
        case .done: return L("Done")
        case .planned: return L("Coming")
        case .thanks: return L("Read — thank you")
        case .notNow: return L("Not for now")
        }
    }
}

/// `suggestions/replies.json` in the repository.
public struct SuggestionReplies: Codable, Hashable, Sendable {
    public var replies: [SuggestionReply] = []

    public init(replies: [SuggestionReply] = []) {
        self.replies = replies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One bad entry must not hide the rest.
        let raw = (try? c.decodeIfPresent([Lenient].self, forKey: .replies)) ?? []
        replies = raw.compactMap(\.reply)
    }

    private struct Lenient: Decodable {
        let reply: SuggestionReply?
        init(from decoder: Decoder) throws {
            reply = try? SuggestionReply(from: decoder)
        }
    }

    public func reply(for id: String) -> SuggestionReply? {
        replies.last { $0.id == id }
    }

    /// Where it is published, beside `update.json`.
    public static func url(for source: UpdateChannel) -> URL? {
        guard let manifest = source.manifestURL else { return nil }
        return manifest.deletingLastPathComponent().appendingPathComponent("suggestions/replies.json")
    }
}
