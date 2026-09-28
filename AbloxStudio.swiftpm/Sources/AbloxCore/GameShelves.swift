import Foundation

// The Games tab, the second round: a search that finds a game however it is
// typed, the player's own lists and star ratings, games to play later, and
// more shelves — not played yet, like one you liked, quick to load, better
// together, updated since you played, this week's pick. All rules, no
// screens: tested here.

// MARK: - Searching

public enum SearchText {

    /// Text as a search compares it: one case, one width (ｶﾞｰﾑ and Ｇａｍｅ
    /// as ガーム and game), and hiragana as katakana, so れーす finds レース.
    public static func fold(_ text: String) -> String {
        let normal = text.precomposedStringWithCompatibilityMapping.lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in normal.unicodeScalars {
            // Hiragana ぁ…ゖ and ゝゞ sit 0x60 below their katakana.
            if (0x3041...0x3096).contains(scalar.value) || (0x309D...0x309E).contains(scalar.value),
               let katakana = Unicode.Scalar(scalar.value + 0x60) {
                scalars.append(katakana)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Whether every word of the search is found in one of the fields.
    public static func matches(_ query: String, in fields: [String]) -> Bool {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let folded = fields.map(fold)
        return words.allSatisfy { word in folded.contains { $0.contains(word) } }
    }

    /// Titles to finish a search with: those starting with it first, then
    /// those containing it.
    public static func suggestions(for query: String, in titles: [String], limit: Int = 5) -> [String] {
        let wanted = fold(query.trimmingCharacters(in: .whitespaces))
        guard wanted.count >= 1 else { return [] }
        let starting = titles.filter { fold($0).hasPrefix(wanted) }
        let containing = titles.filter { !fold($0).hasPrefix(wanted) && fold($0).contains(wanted) }
        var seen = Set<String>()
        return Array((starting + containing).filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// The title nearest a search that found nothing ("Did you mean…?"),
    /// when one is close enough to be what was meant.
    public static func closest(to query: String, in titles: [String]) -> String? {
        let wanted = fold(query.trimmingCharacters(in: .whitespaces))
        guard wanted.count >= 3 else { return nil }
        let allowed = Swift.max(1, wanted.count / 3)
        var best: (title: String, distance: Int)?
        for title in titles {
            let folded = fold(title)
            // A typo in part of a long title counts: compare with the part
            // of the same length that is closest.
            let distance = bestWindowDistance(wanted, in: folded)
            if distance <= allowed, distance < (best?.distance ?? .max) { best = (title, distance) }
        }
        return best?.title
    }

    static func bestWindowDistance(_ query: String, in text: String) -> Int {
        let q = Array(query), t = Array(text)
        guard t.count > q.count else { return editDistance(q, t) }
        var best = Int.max
        for start in 0...(t.count - q.count) {
            best = Swift.min(best, editDistance(q, Array(t[start..<(start + q.count)])))
            if best == 0 { break }
        }
        return best
    }

    /// Levenshtein distance.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Filters

/// Quick ways to narrow the list, beside tags and players.
public enum GameFilter: String, Codable, CaseIterable, Sendable, Identifiable {
    case downloaded, notPlayed, favourites, playLater, gentle, notHard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .downloaded: return L("Downloaded")
        case .notPlayed: return L("Not played yet")
        case .favourites: return L("Favourites")
        case .playLater: return L("Play later")
        case .gentle: return L("Gentle")
        case .notHard: return L("Not too hard")
        }
    }

    public var symbolName: String {
        switch self {
        case .downloaded: return "arrow.down.circle.fill"
        case .notPlayed: return "sparkle"
        case .favourites: return "star.fill"
        case .playLater: return "bookmark.fill"
        case .gentle: return "leaf.fill"
        case .notHard: return "tortoise.fill"
        }
    }

    /// What a filter needs to know about the player.
    public struct Context: Sendable {
        public var downloaded: Set<String> = []
        public var played: Set<String> = []
        public var favourites: Set<String> = []
        public var playLater: Set<String> = []

        public init(downloaded: Set<String> = [], played: Set<String> = [], favourites: Set<String> = [], playLater: Set<String> = []) {
            self.downloaded = downloaded
            self.played = played
            self.favourites = favourites
            self.playLater = playLater
        }
    }

    public func allows(_ listing: GameListing, _ context: Context) -> Bool {
        switch self {
        case .downloaded: return context.downloaded.contains(listing.id)
        case .notPlayed: return !context.played.contains(listing.id)
        case .favourites: return context.favourites.contains(listing.id)
        case .playLater: return context.playLater.contains(listing.id)
        case .gentle: return CatalogueShelf.traits(of: listing).gentle
        case .notHard: return !CatalogueShelf.traits(of: listing).hard
        }
    }
}

/// How the list of games is laid out.
public enum GamesLayout: String, Codable, CaseIterable, Sendable {
    case bigCards, smallCards, list

    public var displayName: String {
        switch self {
        case .bigCards: return L("Big cards")
        case .smallCards: return L("Small cards")
        case .list: return L("List")
        }
    }

    public var symbolName: String {
        switch self {
        case .bigCards: return "square.grid.2x2"
        case .smallCards: return "square.grid.3x3"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - The player's own lists

/// Lists of games a player makes: "Racing", "With Grandma".
public struct GameCollections: Codable, Hashable, Sendable {

    public struct Collection: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var games: [String]

        public init(id: UUID = UUID(), name: String, games: [String] = []) {
            self.id = id
            self.name = name
            self.games = games
        }
    }

    public private(set) var all: [Collection] = []

    public static let maximumCollections = 12
    public static let maximumGames = 100
    public static let maximumNameLength = 30

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let stored = (try? c.decode([Collection].self)) ?? []
        all = Array(stored.prefix(Self.maximumCollections)).map { collection in
            var kept = collection
            kept.name = String(kept.name.prefix(Self.maximumNameLength))
            kept.games = Array(kept.games.prefix(Self.maximumGames))
            return kept
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(all)
    }

    /// A new, empty list; nil for an empty name or when there are enough.
    @discardableResult
    public mutating func create(_ name: String) -> UUID? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        guard !trimmed.isEmpty, all.count < Self.maximumCollections else { return nil }
        let collection = Collection(name: trimmed)
        all.append(collection)
        return collection.id
    }

    public mutating func rename(_ id: UUID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        guard !trimmed.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = trimmed
    }

    public mutating func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
    }

    /// Puts a game in a list, or takes it out; true when it is now in.
    @discardableResult
    public mutating func toggle(_ game: String, in id: UUID) -> Bool {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        if let place = all[index].games.firstIndex(of: game) {
            all[index].games.remove(at: place)
            return false
        }
        guard all[index].games.count < Self.maximumGames else { return false }
        all[index].games.append(game)
        return true
    }

    public func contains(_ game: String, in id: UUID) -> Bool {
        all.first { $0.id == id }?.games.contains(game) ?? false
    }

    /// Takes a game out of every list (when it leaves the catalogue).
    public mutating func forget(_ game: String) {
        for index in all.indices { all[index].games.removeAll { $0 == game } }
    }
}

// MARK: - Stars

/// The player's own stars for games, one to five.
public struct GameRatings: Codable, Hashable, Sendable {
    public private(set) var stars: [String: Int] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let stored = (try? c.decode([String: Int].self)) ?? [:]
        stars = stored.filter { (1...5).contains($0.value) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stars)
    }

    /// Sets the stars; 0 (or the same number again) clears them.
    public mutating func rate(_ game: String, _ value: Int) {
        if value <= 0 || stars[game] == value {
            stars[game] = nil
        } else {
            stars[game] = Swift.min(5, value)
        }
    }

    public func stars(for game: String) -> Int { stars[game] ?? 0 }
}

// MARK: - Shelves

public enum GameShelves {

    /// Games not played yet, newest first.
    public static func notPlayed(_ listings: [GameListing], played: Set<String>, limit: Int = 12) -> [GameListing] {
        Array(listings.filter { !played.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// Games sharing the most tags with `listing`, most alike first.
    public static func similar(to listing: GameListing, in listings: [GameListing], limit: Int = 8) -> [GameListing] {
        let tags = Set(listing.tags.map { $0.lowercased() })
        guard !tags.isEmpty else { return [] }
        let scored: [(GameListing, Int)] = listings.compactMap { other in
            guard other.id != listing.id else { return nil }
            let shared = tags.intersection(other.tags.map { $0.lowercased() }).count
            return shared > 0 ? (other, shared) : nil
        }
        return Array(scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }.map(\.0).prefix(limit))
    }

    /// "Because you liked…": games like the one the player liked most
    /// recently, that they have not played.
    public static func becauseYouLiked(_ listings: [GameListing], likedInOrder: [String], played: Set<String>,
                                       limit: Int = 8) -> (source: GameListing, games: [GameListing])? {
        for id in likedInOrder {
            guard let source = listings.first(where: { $0.id == id }) else { continue }
            let games = similar(to: source, in: listings, limit: 50).filter { !played.contains($0.id) }
            if !games.isEmpty { return (source, Array(games.prefix(limit))) }
        }
        return nil
    }

    /// The smallest worlds, quickest to download and start.
    public static func quickToLoad(_ listings: [GameListing], limit: Int = 10) -> [GameListing] {
        Array(listings.filter { $0.blockCount > 0 }.sorted { $0.blockCount < $1.blockCount }.prefix(limit))
    }

    /// Games made for several people.
    public static func betterTogether(_ listings: [GameListing], limit: Int = 10) -> [GameListing] {
        Array(listings.filter { $0.maxPlayers >= 4 && CatalogueShelf.traits(of: $0).social }
            .sorted { $0.maxPlayers > $1.maxPlayers }.prefix(limit))
    }

    /// Games changed since the player last played them.
    public static func updatedSincePlayed(_ listings: [GameListing], lastPlayed: [String: Date]) -> [GameListing] {
        listings.filter { listing in lastPlayed[listing.id].map { listing.updatedAt > $0 } ?? false }
    }

    /// The same game all week for everyone, a different one next week.
    public static func weeklyPick(from listings: [GameListing], on date: Date = Date(),
                                  calendar: Calendar = Calendar(identifier: .iso8601)) -> GameListing? {
        guard !listings.isEmpty else { return nil }
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let key = "\(parts.yearForWeekOfYear ?? 0)-W\(parts.weekOfYear ?? 0)"
        var hash: UInt64 = 0x84222325_cbf29ce4
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let sorted = listings.sorted { $0.id < $1.id }
        return sorted[Int(hash % UInt64(sorted.count))]
    }

    /// Other games by the same maker.
    public static func byAuthor(of listing: GameListing, in listings: [GameListing]) -> [GameListing] {
        let author = listing.author.trimmingCharacters(in: .whitespaces)
        guard !author.isEmpty else { return [] }
        return listings.filter { $0.id != listing.id && $0.author.caseInsensitiveCompare(author) == .orderedSame }
    }

    /// Each tag and how many games have it, most first.
    public static func tagCounts(in listings: [GameListing]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for listing in listings {
            for tag in Set(listing.tags) { counts[tag, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}

/// Games the player looked at lately (opened, not necessarily played),
/// newest first.
public struct RecentlyViewed: Codable, Hashable, Sendable {
    public private(set) var games: [String] = []
    public static let kept = 12

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        games = Array(((try? c.decode([String].self)) ?? []).prefix(Self.kept))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(games)
    }

    public mutating func viewed(_ game: String) {
        games.removeAll { $0 == game }
        games.insert(game, at: 0)
        if games.count > Self.kept { games.removeLast(games.count - Self.kept) }
    }
}
