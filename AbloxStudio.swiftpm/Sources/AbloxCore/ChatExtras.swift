import Foundation

// Chat and friends, the second round: ready-made phrases in groups and the
// player's own, what they said lately, a guard against flooding, tidying
// what arrives (personal details hidden, shouting softened), and how chat,
// bubbles and names look. Rules here; screens in UI/Game/ChatExtrasViews.swift
// and UI/MainMenu/FriendsViews.swift.

// MARK: - Ready-made phrases

/// Quick phrases, in groups, so a small child finds "Help!" fast.
public enum QuickChatGroup: String, CaseIterable, Sendable, Identifiable {
    case hello, play, help, feelings, bye

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hello: return L("Hello")
        case .play: return L("Playing")
        case .help: return L("Help")
        case .feelings: return L("Feelings")
        case .bye: return L("Goodbye")
        }
    }

    public var symbolName: String {
        switch self {
        case .hello: return "hand.wave.fill"
        case .play: return "gamecontroller.fill"
        case .help: return "lifepreserver.fill"
        case .feelings: return "heart.fill"
        case .bye: return "figure.walk.departure"
        }
    }

    /// English keys, translated when shown and sent.
    public var phrases: [String] {
        switch self {
        case .hello:
            return ["Hi!", "Hello everyone!", "Good morning!", "Good afternoon!", "Good evening!", "Nice to meet you!",
                    "Welcome!", "What's your name?"]
        case .play:
            return ["Let's play together!", "Follow me!", "Over here!", "Let's go!", "One more round?", "Ready?",
                    "Race you!", "Let's team up!", "Your turn!", "Watch this!", "Let's build something!", "Let's explore!"]
        case .help:
            return ["Help!", "Wait for me!", "I'm stuck!", "How do I do this?", "Can you help me?", "Where are you?",
                    "I'm on my way!", "Hold on!"]
        case .feelings:
            return ["Nice!", "Good game!", "Thank you!", "Sorry!", "Well done!", "That was fun!", "Wow!", "Cool!",
                    "Haha!", "Oops!"]
        case .bye:
            return ["See you!", "I have to go.", "Bye for now!", "See you tomorrow!", "Thanks for playing!", "Be right back!"]
        }
    }

    /// Every phrase in every group, once.
    public static var allPhrases: [String] {
        var seen = Set<String>()
        return allCases.flatMap(\.phrases).filter { seen.insert($0).inserted }
    }
}

/// Emoji to send with one tap.
public enum ChatEmoji {
    public static let all = ["👍", "😂", "❤️", "🎉", "😮", "😢", "😎", "🔥", "👋", "🙏", "⭐️", "💯"]
}

/// Phrases of the player's own, typed once and sent with one tap. Nothing
/// the chat filter would mask can be kept.
public struct SavedPhrases: Codable, Hashable, Sendable {
    public private(set) var phrases: [String] = []
    public static let maximum = 8
    public static let maximumLength = 40

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let stored = (try? c.decode([String].self)) ?? []
        phrases = Array(stored.map { String($0.prefix(Self.maximumLength)) }.filter { !$0.isEmpty }.prefix(Self.maximum))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(phrases)
    }

    public enum AddResult: Equatable, Sendable {
        case added, empty, full, duplicate, notAllowed
    }

    public mutating func add(_ text: String, moderator: ChatModerator = ChatModerator()) -> AddResult {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumLength))
        guard !trimmed.isEmpty else { return .empty }
        guard !phrases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return .duplicate }
        guard phrases.count < Self.maximum else { return .full }
        guard !moderator.filter(trimmed).wasFiltered, ChatTidy.personalInfoHidden(trimmed) == trimmed else { return .notAllowed }
        phrases.append(trimmed)
        return .added
    }

    public mutating func remove(_ text: String) {
        phrases.removeAll { $0 == text }
    }

    /// As a list's drag to reorder: `destination` is the place in the list
    /// before the move.
    public mutating func move(from source: Int, to destination: Int) {
        guard phrases.indices.contains(source), destination >= 0, destination <= phrases.count else { return }
        let phrase = phrases.remove(at: source)
        phrases.insert(phrase, at: destination > source ? destination - 1 : destination)
    }
}

/// What this player said lately, newest first, to say again with a tap.
public struct SentHistory: Hashable, Sendable {
    public private(set) var lines: [String] = []
    public static let kept = 10

    public init() {}

    public mutating func said(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.removeAll { $0 == trimmed }
        lines.insert(trimmed, at: 0)
        if lines.count > Self.kept { lines.removeLast(lines.count - Self.kept) }
    }
}

// MARK: - Flooding

/// Stops one player filling everyone's screen: no more than a few lines in
/// a short while, and not the same line again straight away. Checked before
/// a message is sent.
public struct ChatRateLimiter: Hashable, Sendable {
    public static let window: TimeInterval = 10
    public static let maximumInWindow = 5
    public static let repeatGap: TimeInterval = 5

    private var sent: [(Double, String)] = []

    public init() {}

    public enum Verdict: Equatable, Sendable {
        case ok
        /// Too many lines in a short while; wait this many seconds.
        case tooFast(seconds: Int)
        /// The same thing again, straight away.
        case repeated
    }

    public func check(_ text: String, at time: TimeInterval) -> Verdict {
        let key = Self.key(text)
        let recent = sent.filter { time - $0.0 < Self.window }
        if let last = recent.last(where: { $0.1 == key }), time - last.0 < Self.repeatGap { return .repeated }
        if recent.count >= Self.maximumInWindow, let oldest = recent.first {
            return .tooFast(seconds: Swift.max(1, Int((Self.window - (time - oldest.0)).rounded(.up))))
        }
        return .ok
    }

    /// Checks and, when allowed, remembers the line.
    public mutating func allow(_ text: String, at time: TimeInterval) -> Verdict {
        let verdict = check(text, at: time)
        if verdict == .ok {
            sent.append((time, Self.key(text)))
            sent.removeAll { time - $0.0 >= Self.window }
        }
        return verdict
    }

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func == (lhs: ChatRateLimiter, rhs: ChatRateLimiter) -> Bool {
        lhs.sent.map(\.0) == rhs.sent.map(\.0) && lhs.sent.map(\.1) == rhs.sent.map(\.1)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sent.count)
    }
}

// MARK: - Tidying what arrives

public enum ChatTidy {

    /// Phone numbers, email addresses and links replaced with "•••", so a
    /// child cannot be asked for — or give — a way to be reached outside the
    /// game. Numbers of up to six digits (scores, times, room numbers) stay.
    public static func personalInfoHidden(_ text: String) -> String {
        var output = text
        // Email addresses, before links swallow their second half.
        output = replace(#"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#, in: output)
        // Links and web addresses.
        output = replace(#"(?i)\b((https?://|www\.)\S+|[a-z0-9-]+\.(com|net|org|jp|io|co|me|gg|tv|app|xyz)(/\S*)?)"#, in: output)
        // Seven or more digits, allowing spaces, dashes, dots and brackets
        // between them, in ASCII or full-width.
        output = replace(#"[+＋]?[0-9０-９](?:[\s\-.()（）ー－]*[0-9０-９]){6,}"#, in: output)
        return output
    }

    /// "HELLO EVERYONE" as "Hello everyone": capitals shouted across a
    /// whole line are softened; short ones ("OK", "GG") are left.
    public static func shoutingSoftened(_ text: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }
        guard letters.count >= 8 else { return text }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        guard Double(upper) / Double(letters.count) > 0.8 else { return text }
        let lower = text.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// "Hiiiiiiiii!!!!!!" as "Hiii!!!": more than three of the same
    /// character in a row are cut to three.
    public static func repeatsSquashed(_ text: String) -> String {
        var output = ""
        var last: Character?
        var run = 0
        for character in text {
            if character == last {
                run += 1
            } else {
                last = character
                run = 1
            }
            if run <= 3 { output.append(character) }
        }
        return output
    }

    /// Whether a message names the player: their name as a word, in any
    /// case, or with an @ in front.
    public static func mentions(_ name: String, in text: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: trimmed, options: [.caseInsensitive], range: searchRange) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !(before.map(isWordCharacter) ?? false), !(after.map(isWordCharacter) ?? false) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// Everything the player chose, in order.
    public static func tidy(_ text: String, options: ChatOptions) -> String {
        var output = text
        if options.hidePersonalInfo { output = personalInfoHidden(output) }
        if options.softenShouting { output = shoutingSoftened(output) }
        if options.squashRepeats { output = repeatsSquashed(output) }
        return output
    }

    private static func replace(_ pattern: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: "•••")
    }
}

// MARK: - How chat looks

public enum ChatTextSize: String, Codable, CaseIterable, Sendable {
    case small, standard, large

    public var displayName: String {
        switch self {
        case .small: return L("Small")
        case .standard: return L("Standard")
        case .large: return L("Large")
        }
    }

    /// Times the usual size, for chat lines, bubbles and names.
    public var scale: Double {
        switch self {
        case .small: return 0.85
        case .standard: return 1
        case .large: return 1.25
        }
    }
}

/// How long a bubble stays over someone's head.
public enum BubbleTime: String, Codable, CaseIterable, Sendable {
    case short, standard, long

    public var seconds: Double {
        switch self {
        case .short: return 5
        case .standard: return 8
        case .long: return 14
        }
    }

    public var displayName: String {
        switch self {
        case .short: return L("Short")
        case .standard: return L("Standard")
        case .long: return L("Long")
        }
    }
}

/// Whose names float over their heads.
public enum NameTagMode: String, Codable, CaseIterable, Sendable {
    case everyone, friends, nobody

    public var displayName: String {
        switch self {
        case .everyone: return L("Everyone")
        case .friends: return L("Only friends")
        case .nobody: return L("Nobody")
        }
    }
}

/// How the chat, bubbles and names look and behave. One field of
/// `PlayPreferences`, read tolerantly.
public struct ChatOptions: Codable, Hashable, Sendable {
    public var textSize: ChatTextSize = .standard
    public var showTimes = false
    /// Lines shown in the chat panel.
    public var lines = 5
    public static let lineChoices = [3, 5, 8]
    /// Only the newest line, until the panel is tapped.
    public var compact = false
    public var showEmojiBar = true
    public var highlightMentions = true
    /// A friend's nickname and a star in the chat.
    public var markFriends = true
    public var readAloud = false
    public var feelNewMessages = false
    public var hidePersonalInfo = true
    public var softenShouting = true
    public var squashRepeats = true
    // Over heads.
    public var showBubbles = true
    public var bubbleSize: ChatTextSize = .standard
    public var bubbleTime: BubbleTime = .standard
    public var nameTags: NameTagMode = .everyone
    public var nameSize: ChatTextSize = .standard

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatOptions()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        textSize = read(.textSize, d.textSize)
        showTimes = read(.showTimes, d.showTimes)
        lines = read(.lines, d.lines)
        if !Self.lineChoices.contains(lines) { lines = d.lines }
        compact = read(.compact, d.compact)
        showEmojiBar = read(.showEmojiBar, d.showEmojiBar)
        highlightMentions = read(.highlightMentions, d.highlightMentions)
        markFriends = read(.markFriends, d.markFriends)
        readAloud = read(.readAloud, d.readAloud)
        feelNewMessages = read(.feelNewMessages, d.feelNewMessages)
        hidePersonalInfo = read(.hidePersonalInfo, d.hidePersonalInfo)
        softenShouting = read(.softenShouting, d.softenShouting)
        squashRepeats = read(.squashRepeats, d.squashRepeats)
        showBubbles = read(.showBubbles, d.showBubbles)
        bubbleSize = read(.bubbleSize, d.bubbleSize)
        bubbleTime = read(.bubbleTime, d.bubbleTime)
        nameTags = read(.nameTags, d.nameTags)
        nameSize = read(.nameSize, d.nameSize)
    }

    /// Whether a name goes over someone's head.
    public func showsName(isFriend: Bool) -> Bool {
        switch nameTags {
        case .everyone: return true
        case .friends: return isFriend
        case .nobody: return false
        }
    }

    /// A bubble's age as the overlay counts it, which always runs for the
    /// standard eight seconds: a longer choice makes it age more slowly.
    public func bubbleAge(_ seconds: Double) -> Double {
        seconds * BubbleTime.standard.seconds / bubbleTime.seconds
    }
}

// MARK: - Friends

/// A label for a friend, to find them quickly.
public enum FriendGroup: String, CaseIterable, Sendable, Identifiable {
    case school, family, neighbours, club, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .school: return L("School")
        case .family: return L("Family")
        case .neighbours: return L("Neighbours")
        case .club: return L("Club")
        case .other: return L("Other")
        }
    }

    public var symbolName: String {
        switch self {
        case .school: return "backpack.fill"
        case .family: return "house.fill"
        case .neighbours: return "building.2.fill"
        case .club: return "sportscourt.fill"
        case .other: return "tag.fill"
        }
    }
}

/// How the friends list is ordered. Favourites always come first.
public enum FriendSort: String, CaseIterable, Sendable, Identifiable {
    case name, lastSeen, timesMet

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return L("Name")
        case .lastSeen: return L("Last played")
        case .timesMet: return L("Most played with")
        }
    }
}

public extension PlayerContact {
    var group: FriendGroup? {
        get { groupName.flatMap(FriendGroup.init(rawValue:)) }
        set { groupName = newValue?.rawValue }
    }

    var isFavourite: Bool { favourite ?? false }

    /// Whether a search matches their name, nickname, note or last game.
    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [name, nickname ?? "", note ?? "", lastGame].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

public extension SocialBook {

    static let maximumNoteLength = 80

    /// Friends in the order asked for, favourites first, narrowed to a
    /// group and a search.
    func friends(sortedBy sort: FriendSort, group: FriendGroup? = nil, search: String = "") -> [PlayerContact] {
        let chosen = friends.filter { (group == nil || $0.group == group) && $0.matches(search) }
        return chosen.sorted { a, b in
            if a.isFavourite != b.isFavourite { return a.isFavourite }
            switch sort {
            case .name:
                return a.shownName.localizedCaseInsensitiveCompare(b.shownName) == .orderedAscending
            case .lastSeen:
                return a.lastSeen > b.lastSeen
            case .timesMet:
                return a.timesMet != b.timesMet ? a.timesMet > b.timesMet
                    : a.shownName.localizedCaseInsensitiveCompare(b.shownName) == .orderedAscending
            }
        }
    }

    /// People played with since the start of `day`.
    func metToday(now: Date = Date(), calendar: Calendar = .current) -> [PlayerContact] {
        let start = calendar.startOfDay(for: now)
        return recent.filter { $0.lastSeen >= start }
    }

    /// The friend played with most often.
    var closestFriend: PlayerContact? {
        friends.max { $0.timesMet < $1.timesMet }
    }
}
