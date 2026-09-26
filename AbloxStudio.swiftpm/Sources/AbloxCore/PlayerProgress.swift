import Foundation

// A player's progress across all games, and the small decisions the menus
// make about the catalogue: the daily bonus, badges and titles, how rare an
// item is, today's pick, what is new, how hard or scary a game looks, the
// quests a game has, and save slots. All rules, no screens: tested here.

// MARK: - Daily bonus

/// Coins for coming back: more for each day in a row, up to a cap.
public struct DailyBonus: Codable, Hashable, Sendable {
    public private(set) var lastDay: String?
    public private(set) var streak = 0

    public static let base = 10
    public static let perDay = 5
    public static let maximum = 50

    public init() {}

    /// Coins to give today, or nil when today's has been given. Missing a
    /// day starts the streak again.
    public mutating func claim(on date: Date = Date(), calendar: Calendar = .current) -> Int? {
        let today = PlaytimeLog.dayKey(date, calendar: calendar)
        guard today != lastDay else { return nil }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date).map { PlaytimeLog.dayKey($0, calendar: calendar) }
        streak = (lastDay != nil && lastDay == yesterday) ? streak + 1 : 1
        lastDay = today
        return min(Self.maximum, Self.base + Self.perDay * (streak - 1))
    }

    /// Whether there is a bonus waiting today.
    public func isWaiting(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        PlaytimeLog.dayKey(date, calendar: calendar) != lastDay
    }
}

// MARK: - Badges

/// What a player has done, for badges.
public struct ProgressStats: Hashable, Sendable {
    public var gamesPlayed: Int
    public var totalMinutes: Int
    public var daysPlayed: Int
    public var lifetimeCoins: Int
    public var itemsOwned: Int
    public var pictures: Int
    public var worldsMade: Int
    public var hasPet: Bool
    public var bestStreak: Int

    public init(gamesPlayed: Int = 0, totalMinutes: Int = 0, daysPlayed: Int = 0, lifetimeCoins: Int = 0, itemsOwned: Int = 0,
                pictures: Int = 0, worldsMade: Int = 0, hasPet: Bool = false, bestStreak: Int = 0) {
        self.gamesPlayed = gamesPlayed
        self.totalMinutes = totalMinutes
        self.daysPlayed = daysPlayed
        self.lifetimeCoins = lifetimeCoins
        self.itemsOwned = itemsOwned
        self.pictures = pictures
        self.worldsMade = worldsMade
        self.hasPet = hasPet
        self.bestStreak = bestStreak
    }
}

/// Badges earned across every game — and each one a title to wear.
public enum Achievement: String, CaseIterable, Sendable, Identifiable {
    case firstGame, explorer, globetrotter
    case playtime, marathon, regular
    case saver, rich, tycoon
    case stylist, collector
    case photographer, builder, petFriend, loyal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firstGame: return L("Newcomer")
        case .explorer: return L("Adventurer")
        case .globetrotter: return L("Globetrotter")
        case .playtime: return L("Gamer")
        case .marathon: return L("Marathon Player")
        case .regular: return L("Regular")
        case .saver: return L("Saver")
        case .rich: return L("Rich")
        case .tycoon: return L("Tycoon")
        case .stylist: return L("Stylist")
        case .collector: return L("Collector")
        case .photographer: return L("Photographer")
        case .builder: return L("Builder")
        case .petFriend: return L("Pet Friend")
        case .loyal: return L("Loyal")
        }
    }

    public var detail: String {
        switch self {
        case .firstGame: return L("Play a game")
        case .explorer: return L("Play 10 different games")
        case .globetrotter: return L("Play 30 different games")
        case .playtime: return L("Play for an hour in all")
        case .marathon: return L("Play for 10 hours in all")
        case .regular: return L("Play on 7 different days")
        case .saver: return L("Earn 500 coins")
        case .rich: return L("Earn 3,000 coins")
        case .tycoon: return L("Earn 20,000 coins")
        case .stylist: return L("Own 15 items")
        case .collector: return L("Own 40 items")
        case .photographer: return L("Take 10 pictures")
        case .builder: return L("Make a world of your own")
        case .petFriend: return L("Have a pet")
        case .loyal: return L("Come back 7 days in a row")
        }
    }

    public var symbolName: String {
        switch self {
        case .firstGame: return "sparkles"
        case .explorer: return "map.fill"
        case .globetrotter: return "globe.asia.australia.fill"
        case .playtime: return "clock.fill"
        case .marathon: return "figure.run"
        case .regular: return "calendar"
        case .saver: return "banknote"
        case .rich: return "dollarsign.circle.fill"
        case .tycoon: return "crown.fill"
        case .stylist: return "tshirt.fill"
        case .collector: return "square.grid.3x3.fill"
        case .photographer: return "camera.fill"
        case .builder: return "hammer.fill"
        case .petFriend: return "pawprint.fill"
        case .loyal: return "heart.fill"
        }
    }

    public func isEarned(_ s: ProgressStats) -> Bool {
        switch self {
        case .firstGame: return s.gamesPlayed >= 1
        case .explorer: return s.gamesPlayed >= 10
        case .globetrotter: return s.gamesPlayed >= 30
        case .playtime: return s.totalMinutes >= 60
        case .marathon: return s.totalMinutes >= 600
        case .regular: return s.daysPlayed >= 7
        case .saver: return s.lifetimeCoins >= 500
        case .rich: return s.lifetimeCoins >= 3_000
        case .tycoon: return s.lifetimeCoins >= 20_000
        case .stylist: return s.itemsOwned >= 15
        case .collector: return s.itemsOwned >= 40
        case .photographer: return s.pictures >= 10
        case .builder: return s.worldsMade >= 1
        case .petFriend: return s.hasPet
        case .loyal: return s.bestStreak >= 7
        }
    }

    public static func earned(_ stats: ProgressStats) -> [Achievement] {
        allCases.filter { $0.isEarned(stats) }
    }
}

// MARK: - Rarity

public enum ItemRarity: Int, Comparable, CaseIterable, Sendable {
    case common, rare, epic, legendary

    public static func < (lhs: ItemRarity, rhs: ItemRarity) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(price: Int) {
        switch price {
        case ..<100: self = .common
        case ..<250: self = .rare
        case ..<450: self = .epic
        default: self = .legendary
        }
    }

    public var displayName: String {
        switch self {
        case .common: return L("Common")
        case .rare: return L("Rare")
        case .epic: return L("Epic")
        case .legendary: return L("Legendary")
        }
    }

    /// "#94A3B8"… for the badge.
    public var colorHex: String {
        switch self {
        case .common: return "#94A3B8"
        case .rare: return "#38BDF8"
        case .epic: return "#C084FC"
        case .legendary: return "#FACC15"
        }
    }
}

// MARK: - The catalogue in the menu

public enum CatalogueShelf {

    /// The same game for everyone all day, a different one tomorrow.
    public static func dailyPick(from listings: [GameListing], on date: Date = Date(), calendar: Calendar = .current) -> GameListing? {
        guard !listings.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in PlaytimeLog.dayKey(date, calendar: calendar).utf8 { hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3 }
        let sorted = listings.sorted { $0.id < $1.id }
        return sorted[Int(hash % UInt64(sorted.count))]
    }

    public enum Freshness: Equatable, Sendable {
        case seen, new, updated
    }

    /// New (never seen here) or updated (seen, but changed since).
    public static func freshness(of listing: GameListing, seen: [String: String]) -> Freshness {
        guard let before = seen[listing.id] else { return .new }
        return before == listing.revisionKey ? .seen : .updated
    }

    /// What the menu can say about a game from its tags.
    public struct Traits: Equatable, Sendable {
        public var scary = false
        public var hard = false
        public var gentle = false
        public var social = false
    }

    public static func traits(of listing: GameListing) -> Traits {
        let tags = Set(listing.tags.map { $0.lowercased() })
        var traits = Traits()
        traits.scary = !tags.isDisjoint(with: ["horror", "tense", "night", "zombies", "monsters"])
        traits.hard = !tags.isDisjoint(with: ["hard", "speedrun", "skill", "pvp"])
        traits.gentle = !tags.isDisjoint(with: ["family", "cute", "chill", "creative", "pets"])
        traits.social = !tags.isDisjoint(with: ["social", "rp", "party", "coop", "teams"])
        return traits
    }

    public enum PlayerCount: String, CaseIterable, Sendable {
        case any, solo, few, many

        public var displayName: String {
            switch self {
            case .any: return L("Any number")
            case .solo: return L("On my own")
            case .few: return L("2–4 players")
            case .many: return L("5 or more")
            }
        }

        public func allows(_ listing: GameListing) -> Bool {
            switch self {
            case .any: return true
            case .solo: return listing.maxPlayers >= 1
            case .few: return listing.maxPlayers >= 2
            case .many: return listing.maxPlayers >= 5
            }
        }
    }

    /// The tags most games share, for filter buttons.
    public static func commonTags(in listings: [GameListing], limit: Int = 12) -> [String] {
        var counts: [String: Int] = [:]
        for listing in listings {
            for tag in listing.tags where tag != "top20" { counts[tag, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// A game's quests, read from its scripts: `kit_quest("id", "Title", goal, reward)`.
    public static func quests(inScripts sources: [String]) -> [(title: String, reward: Int)] {
        var found: [(String, Int)] = []
        let pattern = #"kit_quest\(\s*"[^"]*"\s*,\s*"([^"]+)"\s*,\s*[^,]+,\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for source in sources {
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let title = Range(match.range(at: 1), in: source), let reward = Range(match.range(at: 2), in: source) else { continue }
                found.append((String(source[title]), Int(source[reward]) ?? 0))
            }
        }
        return found
    }

    /// The how-to-play lines a game shows when you arrive:
    /// `kit_setup("Name", "tagline", ["line", …])`.
    public static func instructions(inScripts sources: [String]) -> [String] {
        for source in sources {
            guard let start = source.range(of: "kit_setup(") else { continue }
            let rest = source[start.upperBound...]
            guard let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") else { continue }
            let list = rest[rest.index(after: open)..<close]
            var lines: [String] = []
            var current = ""
            var inString = false
            var escaped = false
            for character in list {
                if inString {
                    if escaped { current.append(character); escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                        inString = false
                        lines.append(current)
                        current = ""
                    } else { current.append(character) }
                } else if character == "\"" {
                    inString = true
                }
            }
            if !lines.isEmpty { return lines }
        }
        return []
    }
}

public extension GameListing {
    /// What changes when the game does: the cover's name (which carries the
    /// picture's fingerprint), the block count and the scripts listed.
    var revisionKey: String {
        "\(cover ?? "")|\(blockCount)|\((scripts ?? []).count)|\(schemaVersion)"
    }
}

// MARK: - Save slots

public enum SaveSlots {
    public static let count = 3

    /// The id a slot's saves are kept under. Slot 1 is the world's own id,
    /// so saves made before slots existed are slot 1.
    public static func storageID(world: UUID, slot: Int) -> UUID {
        guard slot > 1 else { return world }
        var bytes = PeerID(world).bytes
        bytes[15] ^= UInt8(truncatingIfNeeded: slot * 37)
        bytes[14] ^= 0xA5
        return PeerID(bytes: bytes)?.raw ?? world
    }
}
