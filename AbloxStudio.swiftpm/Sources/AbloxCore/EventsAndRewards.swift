import Foundation

// Missions, events and coins, the second round: missions for the week,
// seasons and festivals with their own bonus and sale, streak milestones,
// the shop's deal of the day, a coin jar that grows while it is left alone,
// coins for badges and first visits, a birthday, and the week in numbers.
// All rules, no screens: tested here.

// MARK: - This week's missions

/// Three bigger missions a week, the same for everyone that week.
public struct WeeklyMissionBook: Codable, Hashable, Sendable {
    public private(set) var week = ""
    public private(set) var counts: [String: Int] = [:]
    public private(set) var games: [String] = []
    public private(set) var claimed: Set<String> = []

    public static let missionsPerWeek = 3

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = (try? c.decodeIfPresent(String.self, forKey: .week)) ?? ""
        counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
        games = (try? c.decodeIfPresent([String].self, forKey: .games)) ?? []
        claimed = (try? c.decodeIfPresent(Set<String>.self, forKey: .claimed)) ?? []
    }

    /// "2026-W39".
    public static func weekKey(_ date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) -> String {
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    public static func missions(for week: String) -> [Mission] {
        var seed = MissionBook.stableHash("week:" + week)
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let minutes = [60, 90, 120][next(3)]
        var missions = [Mission(kind: .playMinutes, target: minutes, reward: 40 + minutes / 2)]
        var others: [MissionKind] = [.differentGames, .earnCoins, .takePicture, .useEmote, .playWithOthers, .finishRound]
        while missions.count < missionsPerWeek, !others.isEmpty {
            let kind = others.remove(at: next(others.count))
            let target: Int
            switch kind {
            case .differentGames: target = [4, 6][next(2)]
            case .earnCoins: target = [200, 300][next(2)]
            case .takePicture: target = 5
            case .useEmote: target = 20
            case .playWithOthers: target = 3
            case .finishRound: target = [5, 8][next(2)]
            case .playMinutes: target = 60
            }
            missions.append(Mission(kind: kind, target: target, reward: 60 + 10 * missions.count))
        }
        return missions
    }

    public func missions(on week: String) -> [Mission] { Self.missions(for: week) }

    public mutating func roll(to week: String) {
        guard week != self.week else { return }
        self.week = week
        counts = [:]
        games = []
        claimed = []
    }

    public mutating func record(_ kind: MissionKind, amount: Int = 1, on week: String) {
        roll(to: week)
        guard amount > 0 else { return }
        counts[kind.rawValue, default: 0] += amount
    }

    public mutating func played(game: String, on week: String) {
        roll(to: week)
        guard !game.isEmpty, !games.contains(game) else { return }
        games.append(game)
        if games.count > 50 { games.removeFirst(games.count - 50) }
    }

    public func progress(of mission: Mission, on week: String) -> Int {
        guard week == self.week else { return 0 }
        switch mission.kind {
        case .playMinutes: return (counts[mission.kind.rawValue] ?? 0) / 60
        case .differentGames: return games.count
        default: return counts[mission.kind.rawValue] ?? 0
        }
    }

    public func isDone(_ mission: Mission, on week: String) -> Bool {
        progress(of: mission, on: week) >= mission.target
    }

    public func isClaimed(_ mission: Mission, on week: String) -> Bool {
        week == self.week && claimed.contains(mission.id)
    }

    public mutating func claim(_ mission: Mission, on week: String) -> Int? {
        roll(to: week)
        guard isDone(mission, on: week), !claimed.contains(mission.id) else { return nil }
        claimed.insert(mission.id)
        return mission.reward
    }

    /// For finishing all of a week's missions.
    public static let allDoneBonus = 100

    public func isAllDoneBonusWaiting(on week: String) -> Bool {
        missions(on: week).allSatisfy { isDone($0, on: week) } && !(week == self.week && claimed.contains("all"))
    }

    public mutating func claimAllDoneBonus(on week: String) -> Int? {
        roll(to: week)
        guard isAllDoneBonusWaiting(on: week) else { return nil }
        claimed.insert("all")
        return Self.allDoneBonus
    }

    /// Which missions are done, to notice one finishing.
    public func done(on week: String) -> Set<String> {
        Set(missions(on: week).filter { isDone($0, on: week) }.map(\.id))
    }

    /// Whole days left this week after today (Sunday is 0).
    public static func daysLeft(on date: Date, calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        let today = calendar.startOfDay(for: date)
        return Swift.max(0, (calendar.dateComponents([.day], from: today, to: interval.end).day ?? 1) - 1)
    }
}

// MARK: - Seasons and festivals

/// Something happening this time of year: a banner, a coin bonus, a sale
/// on a few things in the shop, and one more mission a day.
public enum SeasonalEvent: String, CaseIterable, Sendable, Identifiable {
    case newYear, setsubun, valentine, hanami, childrensDay, rainySeason, tanabata, summer, moonViewing,
         halloween, autumnLeaves, christmas, yearEnd

    public var id: String { rawValue }

    /// First and last day, as (month, day); both included.
    public var dates: (start: (Int, Int), end: (Int, Int)) {
        switch self {
        case .newYear: return ((1, 1), (1, 7))
        case .setsubun: return ((2, 1), (2, 4))
        case .valentine: return ((2, 10), (2, 14))
        case .hanami: return ((3, 25), (4, 10))
        case .childrensDay: return ((5, 1), (5, 5))
        case .rainySeason: return ((6, 10), (6, 30))
        case .tanabata: return ((7, 1), (7, 7))
        case .summer: return ((7, 20), (8, 31))
        case .moonViewing: return ((9, 15), (9, 25))
        case .halloween: return ((10, 20), (10, 31))
        case .autumnLeaves: return ((11, 10), (11, 30))
        case .christmas: return ((12, 18), (12, 25))
        case .yearEnd: return ((12, 26), (12, 31))
        }
    }

    public var displayName: String {
        switch self {
        case .newYear: return L("New Year")
        case .setsubun: return L("Setsubun")
        case .valentine: return L("Valentine's")
        case .hanami: return L("Cherry blossoms")
        case .childrensDay: return L("Children's Day")
        case .rainySeason: return L("Rainy season")
        case .tanabata: return L("Tanabata")
        case .summer: return L("Summer holidays")
        case .moonViewing: return L("Moon viewing")
        case .halloween: return L("Halloween")
        case .autumnLeaves: return L("Autumn leaves")
        case .christmas: return L("Christmas")
        case .yearEnd: return L("End of the year")
        }
    }

    public var symbolName: String {
        switch self {
        case .newYear: return "sun.horizon.fill"
        case .setsubun: return "circle.grid.cross.fill"
        case .valentine: return "heart.fill"
        case .hanami: return "leaf.fill"
        case .childrensDay: return "wind"
        case .rainySeason: return "umbrella.fill"
        case .tanabata: return "sparkles"
        case .summer: return "sun.max.fill"
        case .moonViewing: return "moon.fill"
        case .halloween: return "moon.stars.fill"
        case .autumnLeaves: return "leaf.arrow.triangle.circlepath"
        case .christmas: return "gift.fill"
        case .yearEnd: return "bell.fill"
        }
    }

    /// Two colours for its banner.
    public var colours: (ColorRGBA, ColorRGBA) {
        func hex(_ value: String) -> ColorRGBA { ColorRGBA(hex: value) ?? ColorRGBA(r: 1, g: 1, b: 1) }
        switch self {
        case .newYear: return (hex("#DC2626"), hex("#FACC15"))
        case .setsubun: return (hex("#F59E0B"), hex("#7C2D12"))
        case .valentine: return (hex("#EC4899"), hex("#F43F5E"))
        case .hanami: return (hex("#F9A8D4"), hex("#FBCFE8"))
        case .childrensDay: return (hex("#2563EB"), hex("#EF4444"))
        case .rainySeason: return (hex("#6366F1"), hex("#22D3EE"))
        case .tanabata: return (hex("#1E3A8A"), hex("#FDE047"))
        case .summer: return (hex("#F97316"), hex("#06B6D4"))
        case .moonViewing: return (hex("#1E1B4B"), hex("#FDE68A"))
        case .halloween: return (hex("#EA580C"), hex("#581C87"))
        case .autumnLeaves: return (hex("#B91C1C"), hex("#F59E0B"))
        case .christmas: return (hex("#15803D"), hex("#DC2626"))
        case .yearEnd: return (hex("#334155"), hex("#EAB308"))
        }
    }

    /// Extra coins from rounds while it is on, in percent.
    public var coinBonusPercent: Int {
        switch self {
        case .newYear, .christmas, .summer: return 25
        default: return 15
        }
    }

    /// The kind of thing its extra mission asks for.
    public var mission: Mission {
        switch self {
        case .newYear, .yearEnd: return Mission(kind: .playWithOthers, target: 1, reward: 50)
        case .setsubun, .halloween: return Mission(kind: .finishRound, target: 3, reward: 50)
        case .valentine, .childrensDay: return Mission(kind: .useEmote, target: 5, reward: 40)
        case .hanami, .moonViewing, .autumnLeaves, .rainySeason: return Mission(kind: .takePicture, target: 2, reward: 40)
        case .tanabata, .christmas: return Mission(kind: .differentGames, target: 3, reward: 50)
        case .summer: return Mission(kind: .playMinutes, target: 30, reward: 50)
        }
    }

    /// Shop items a quarter off while it is on: a few looks that suit it.
    public var saleItemIDs: [String] {
        switch self {
        case .newYear: return ["hat.crown", "aura.gold", "nameplate.gold"]
        case .setsubun: return ["face.angry", "hat.horns"]
        case .valentine: return ["trail.hearts", "bubble.candy", "nameplate.candy"]
        case .hanami: return ["hat.flower_crown", "trail.leaves", "bubble.sky"]
        case .childrensDay: return ["hat.cap", "pet.dragon", "nameplate.sky"]
        case .rainySeason: return ["trail.bubbles", "bubble.cloud", "nameplate.ice"]
        case .tanabata: return ["trail.stars", "aura.galaxy", "nameplate.midnight"]
        case .summer: return ["trail.sand", "hat.propeller", "bubble.sun"]
        case .moonViewing: return ["pet.bunny", "nameplate.midnight", "bubble.night"]
        case .halloween: return ["hat.witch", "trail.smoke", "nameplate.lava"]
        case .autumnLeaves: return ["trail.leaves", "bubble.lava", "hat.beanie"]
        case .christmas: return ["hat.santa", "trail.snow", "nameplate.royal"]
        case .yearEnd: return ["trail.confetti", "aura.rainbow", "bubble.gold"]
        }
    }

    public static let salePercent = 25

    /// Whether it is on at `date`.
    public func isOn(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return false }
        let now = month * 100 + day
        return now >= dates.start.0 * 100 + dates.start.1 && now <= dates.end.0 * 100 + dates.end.1
    }

    /// The event on at `date`, if any (they never overlap).
    public static func current(on date: Date = Date(), calendar: Calendar = .current) -> SeasonalEvent? {
        allCases.first { $0.isOn(date, calendar: calendar) }
    }

    /// Whole days left after today, 0 on its last day.
    public func daysLeft(on date: Date, calendar: Calendar = .current) -> Int {
        let year = calendar.component(.year, from: date)
        guard let end = calendar.date(from: DateComponents(year: year, month: dates.end.0, day: dates.end.1)) else { return 0 }
        let today = calendar.startOfDay(for: date)
        return Swift.max(0, calendar.dateComponents([.day], from: today, to: end).day ?? 0)
    }

    /// The next one to come, and how many days until it starts.
    public static func next(after date: Date, calendar: Calendar = .current) -> (event: SeasonalEvent, days: Int)? {
        let today = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: date)
        var best: (SeasonalEvent, Int)?
        for event in allCases {
            for offset in [0, 1] {
                guard let start = calendar.date(from: DateComponents(year: year + offset, month: event.dates.start.0,
                                                                     day: event.dates.start.1)) else { continue }
                let days = calendar.dateComponents([.day], from: today, to: start).day ?? -1
                if days > 0, days < (best?.1 ?? .max) { best = (event, days) }
            }
        }
        return best.map { (event: $0.0, days: $0.1) }
    }

    /// Coins with the bonus added.
    public func boosted(_ coins: Int) -> Int {
        coins + (coins * coinBonusPercent + 99) / 100
    }
}

// MARK: - Deals

public enum ShopDeals {

    public static let dealPercent = 30

    /// One locked item a day, the same for everyone, 30% off.
    public static func dailyDeal(on day: String, owned: Set<String>) -> ShopItem? {
        let choices = ShopCatalogue.items.filter { $0.price >= 60 && !owned.contains($0.id) }.sorted { $0.id < $1.id }
        guard !choices.isEmpty else { return nil }
        let hash = MissionBook.stableHash("deal:" + day)
        return choices[Int(hash % UInt64(choices.count))]
    }

    /// What an item costs today: the deal, an event's sale, or its price.
    public static func price(of item: ShopItem, day: String, event: SeasonalEvent?, owned: Set<String>) -> Int {
        var percent = 0
        if dailyDeal(on: day, owned: owned)?.id == item.id { percent = dealPercent }
        if let event, event.saleItemIDs.contains(item.id) { percent = Swift.max(percent, SeasonalEvent.salePercent) }
        return percent == 0 ? item.price : item.price - item.price * percent / 100
    }
}

// MARK: - Streaks

public enum StreakRewards {

    /// Days in a row that earn something extra, and how much.
    public static let milestones: [(days: Int, coins: Int)] = [(3, 20), (7, 60), (14, 120), (30, 300), (60, 500), (100, 1_000)]

    public static func bonus(forStreak days: Int) -> Int? {
        milestones.first { $0.days == days }?.coins
    }

    /// The next milestone after `days`.
    public static func next(after days: Int) -> (days: Int, coins: Int)? {
        milestones.first { $0.days > days }
    }

    /// Weekends give twice the daily bonus.
    public static func weekendMultiplier(on date: Date, calendar: Calendar = .current) -> Int {
        calendar.isDateInWeekend(date) ? 2 : 1
    }

    /// The daily bonus for each of the next `days` days if the streak goes
    /// on, weekends doubled and milestones added — for the streak card.
    public static func preview(streak: Int, from date: Date, days: Int = 7, calendar: Calendar = .current) -> [(date: Date, coins: Int)] {
        (1...Swift.max(1, days)).compactMap { ahead in
            guard let day = calendar.date(byAdding: .day, value: ahead, to: date) else { return nil }
            let length = streak + ahead
            let base = Swift.min(DailyBonus.maximum, DailyBonus.base + DailyBonus.perDay * (length - 1))
            return (day, base * weekendMultiplier(on: day, calendar: calendar) + (bonus(forStreak: length) ?? 0))
        }
    }
}

// MARK: - The coin jar

/// Coins put aside grow by 5% for every whole week they are left, up to 50
/// a week — to show that saving pays. Taking them out is always allowed.
public struct CoinJar: Codable, Hashable, Sendable {
    public private(set) var balance = 0
    /// When interest was last added.
    public private(set) var since: Date?

    public static let weeklyPercent = 5
    public static let weeklyMaximum = 50
    public static let capacity = 5_000
    public static let week: TimeInterval = 7 * 86_400
    /// Coins go in and come out ten at a time.
    public static let step = 10

    /// The top of the jar's slider: the most that could go in or come out,
    /// in whole steps, and never less than one step. When it is one step
    /// there is nothing to choose, and no slider is shown — SwiftUI stops the
    /// app for a slider whose two ends are the same.
    public static func sliderTop(coins: Int, saved: Int) -> Int {
        let canPut = Swift.min(Swift.max(0, coins), capacity - Swift.max(0, saved))
        let most = Swift.max(canPut, saved)
        return Swift.max(step, most / step * step)
    }

    /// The amount picked on the slider, in whole steps from one step to `top`.
    public static func chosen(_ amount: Double, top: Int) -> Int {
        guard !amount.isNaN else { return step }
        let clamped = Swift.min(Swift.max(amount, Double(step)), Double(Swift.max(step, top)))
        return Swift.min(Swift.max(step, Int((clamped / Double(step)).rounded()) * step), Swift.max(step, top))
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balance = Swift.max(0, Swift.min(Self.capacity, (try? c.decodeIfPresent(Int.self, forKey: .balance)) ?? 0))
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
    }

    /// Whole weeks' growth since the last, added; returns how much.
    @discardableResult
    public mutating func grow(now: Date = Date()) -> Int {
        guard balance > 0, let since else {
            self.since = now
            return 0
        }
        let weeks = Int(now.timeIntervalSince(since) / Self.week)
        guard weeks > 0 else { return 0 }
        var added = 0
        for _ in 0..<Swift.min(weeks, 52) {
            let interest = Swift.min(Self.weeklyMaximum, balance * Self.weeklyPercent / 100)
            let room = Self.capacity - balance
            let step = Swift.min(interest, room)
            balance += step
            added += step
        }
        self.since = since.addingTimeInterval(Double(weeks) * Self.week)
        return added
    }

    /// How much could go in now, from `coins`.
    public func room(from coins: Int) -> Int { Swift.max(0, Swift.min(coins, Self.capacity - balance)) }

    public mutating func put(_ amount: Int, now: Date = Date()) {
        guard amount > 0 else { return }
        grow(now: now)
        if balance == 0 { since = now }
        balance = Swift.min(Self.capacity, balance + amount)
    }

    /// Takes coins out; returns how many came out.
    public mutating func take(_ amount: Int, now: Date = Date()) -> Int {
        grow(now: now)
        let out = Swift.max(0, Swift.min(amount, balance))
        balance -= out
        if balance == 0 { since = nil }
        return out
    }

    /// Days until the next growth, for the card.
    public func daysToGrowth(now: Date = Date()) -> Int? {
        guard balance > 0, let since else { return nil }
        let left = Self.week - now.timeIntervalSince(since).truncatingRemainder(dividingBy: Self.week)
        return Int((left / 86_400).rounded(.up))
    }
}

// MARK: - Small gifts

public extension Achievement {
    /// Coins for earning a badge: more for the harder second set.
    var reward: Int {
        let firstSet: Set<Achievement> = [.firstGame, .explorer, .globetrotter, .playtime, .marathon, .regular, .saver,
                                          .rich, .tycoon, .stylist, .collector, .photographer, .builder, .petFriend, .loyal]
        return firstSet.contains(self) ? 25 : 40
    }
}

/// Coins the first time each game is played, and the first time each day
/// the player hosts a room or plays with a friend.
public struct FirstTimes: Codable, Hashable, Sendable {
    public private(set) var games: Set<String> = []
    public private(set) var hostedDay: String?
    public private(set) var friendDay: String?

    public static let newGameCoins = 10
    public static let hostCoins = 10
    public static let friendCoins = 15
    public static let keptGames = 1_000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = (try? c.decodeIfPresent(Set<String>.self, forKey: .games)) ?? []
        hostedDay = try? c.decodeIfPresent(String.self, forKey: .hostedDay)
        friendDay = try? c.decodeIfPresent(String.self, forKey: .friendDay)
    }

    public mutating func firstVisit(_ game: String) -> Int? {
        guard !game.isEmpty, games.count < Self.keptGames, games.insert(game).inserted else { return nil }
        return Self.newGameCoins
    }

    public mutating func hosted(on day: String) -> Int? {
        guard hostedDay != day else { return nil }
        hostedDay = day
        return Self.hostCoins
    }

    public mutating func playedWithFriend(on day: String) -> Int? {
        guard friendDay != day else { return nil }
        friendDay = day
        return Self.friendCoins
    }
}

/// A player's birthday (month and day only), and whether this year's gift
/// was given.
public struct Birthday: Codable, Hashable, Sendable {
    public var month: Int
    public var day: Int
    public private(set) var giftYear: Int?

    public static let giftCoins = 100

    public init(month: Int, day: Int) {
        self.month = Swift.max(1, Swift.min(12, month))
        self.day = Swift.max(1, Swift.min(31, day))
    }

    public func isToday(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return parts.month == month && parts.day == day
    }

    /// This year's gift, once, on the day.
    public mutating func claimGift(on date: Date = Date(), calendar: Calendar = .current) -> Int? {
        let year = calendar.component(.year, from: date)
        guard isToday(date, calendar: calendar), giftYear != year else { return nil }
        giftYear = year
        return Self.giftCoins
    }
}

// MARK: - The week in numbers

public struct WeekSummary: Equatable, Sendable {
    /// The game played longest this week.
    public var favouriteGame: String?
    public var minutes = 0
    public var lastWeekMinutes = 0
    public var coinsEarned = 0
    public var coinsSpent = 0
    public var daysPlayed = 0

    public init() {}

    /// Play and coins in the seven days to `now`, and play the seven before.
    public static func make(days: [PlaytimeLog.Day], ledger: CoinLedger, now: Date = Date(), calendar: Calendar = .current) -> WeekSummary {
        var summary = WeekSummary()
        let today = calendar.startOfDay(for: now)
        guard let weekAgo = calendar.date(byAdding: .day, value: -6, to: today),
              let twoWeeksAgo = calendar.date(byAdding: .day, value: -13, to: today) else { return summary }
        let thisWeek = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekAgo) }.map { PlaytimeLog.dayKey($0, calendar: calendar) })
        let lastWeek = Set((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: twoWeeksAgo) }.map { PlaytimeLog.dayKey($0, calendar: calendar) })
        var perGame: [String: Double] = [:]
        for day in days {
            if thisWeek.contains(day.date) {
                summary.minutes += Int(day.seconds / 60)
                if day.seconds > 0 { summary.daysPlayed += 1 }
                for (game, seconds) in day.games { perGame[game, default: 0] += seconds }
            } else if lastWeek.contains(day.date) {
                summary.lastWeekMinutes += Int(day.seconds / 60)
            }
        }
        summary.favouriteGame = perGame.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        for entry in ledger.entries where entry.date >= weekAgo {
            if entry.amount > 0 { summary.coinsEarned += entry.amount } else { summary.coinsSpent -= entry.amount }
        }
        return summary
    }
}
