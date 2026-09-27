import Foundation

// Finding a game in a long list: orders to sort it in, games put out of
// sight, the last few searches, and a game picked at random for someone who
// cannot decide. All rules, no screens: tested here.

/// The order of "All games".
public enum GameSort: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The list's own order, as its maintainers arranged it.
    case suggested
    case name
    case newest
    case mostPlayed
    case liked
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .suggested: return L("Suggested")
        case .name: return L("Name")
        case .newest: return L("Newest")
        case .mostPlayed: return L("Most played")
        case .liked: return L("Liked first")
        }
    }

    public var symbolName: String {
        switch self {
        case .suggested: return "sparkles"
        case .name: return "textformat"
        case .newest: return "clock.arrow.circlepath"
        case .mostPlayed: return "gamecontroller"
        case .liked: return "heart"
        }
    }
}

public enum CatalogueBrowsing {

    /// `listings` in `order`. Ties keep the list's own order, so the result
    /// never jumps about between two identical calls.
    public static func sorted(_ listings: [GameListing], by order: GameSort,
                              playedSeconds: (GameListing) -> Double = { _ in 0 },
                              liked: Set<String> = []) -> [GameListing] {
        let indexed = Array(listings.enumerated())
        func stable(_ before: (GameListing, GameListing) -> Bool?) -> [GameListing] {
            indexed.sorted { a, b in before(a.element, b.element) ?? (a.offset < b.offset) }.map(\.element)
        }
        switch order {
        case .suggested:
            return listings
        case .name:
            return stable { a, b in
                let result = a.title.localizedStandardCompare(b.title)
                return result == .orderedSame ? nil : result == .orderedAscending
            }
        case .newest:
            return stable { a, b in a.updatedAt == b.updatedAt ? nil : a.updatedAt > b.updatedAt }
        case .mostPlayed:
            return stable { a, b in
                let x = playedSeconds(a), y = playedSeconds(b)
                return x == y ? nil : x > y
            }
        case .liked:
            return stable { a, b in
                let x = liked.contains(a.id), y = liked.contains(b.id)
                return x == y ? nil : x
            }
        }
    }

    /// Everything not put out of sight.
    public static func visible(_ listings: [GameListing], hidden: Set<String>) -> [GameListing] {
        hidden.isEmpty ? listings : listings.filter { !hidden.contains($0.id) }
    }

    /// A game to try: one not played yet when there is one, otherwise any.
    /// The same `seed` picks the same game, for tests; the menu passes a
    /// random one.
    public static func surprise(from listings: [GameListing], played: Set<String>, seed: UInt64) -> GameListing? {
        guard !listings.isEmpty else { return nil }
        let fresh = listings.filter { !played.contains($0.id) }
        let pool = fresh.isEmpty ? listings : fresh
        var mixed = seed ^ 0x9E3779B97F4A7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        mixed ^= mixed >> 31
        return pool[Int(mixed % UInt64(pool.count))]
    }
}

/// The last few searches, newest first, to tap instead of typing again.
public struct RecentSearches: Codable, Hashable, Sendable {
    public private(set) var items: [String] = []
    public static let kept = 8

    public init() {}

    /// Keeps a search worth keeping: trimmed, two letters or more, once.
    public mutating func add(_ text: String) {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard query.count >= 2 else { return }
        items.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        items.insert(query, at: 0)
        if items.count > Self.kept { items.removeLast(items.count - Self.kept) }
    }

    public mutating func remove(_ text: String) {
        items.removeAll { $0 == text }
    }

    public mutating func clear() {
        items.removeAll()
    }
}
