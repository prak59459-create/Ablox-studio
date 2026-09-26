import Foundation

// What a parent can decide for a child's iPad, and the play-time record
// those decisions are checked against.
//
// Everything here stays on the iPad. There is no account and no server, so
// the controls are only as strong as the passcode that guards Settings — which
// is the point: they are for a family to agree on, not a lock against an
// attacker. The rules are here, in the portable core, where they are tested;
// the app shows them and asks.

// MARK: - Quiet hours

/// A stretch of the day when games do not start — bedtime, school time.
/// Minutes after midnight; the range may wrap past midnight (21:00–07:00).
public struct QuietHours: Codable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = Self.wrap(start)
        self.end = Self.wrap(end)
    }

    public func contains(minuteOfDay minute: Int) -> Bool {
        let m = Self.wrap(minute)
        if start == end { return false }
        return start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// "21:00".
    public static func clock(_ minute: Int) -> String {
        let m = wrap(minute)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private static func wrap(_ minute: Int) -> Int {
        ((minute % 1440) + 1440) % 1440
    }
}

// MARK: - Chat

public enum ChatAllowance: String, Codable, CaseIterable, Sendable {
    /// Typing anything, through the word filter.
    case full
    /// Only the ready-made phrases: nothing typed ever leaves the iPad.
    case phrases
    /// No chat at all, in or out.
    case off

    public var displayName: String {
        switch self {
        case .full: return L("Anything (filtered)")
        case .phrases: return L("Ready-made phrases only")
        case .off: return L("Off")
        }
    }
}

/// Ready-made chat lines, for small children and for "phrases only" mode.
/// Sent translated into the sender's language, like anything typed.
public enum QuickChat {
    public static let phrases: [String] = [
        "Hi!", "Let's play together!", "Follow me!", "Wait for me!", "Over here!", "Thank you!",
        "Nice!", "Good game!", "Let's go!", "Help!", "I'm on my way!", "Sorry!", "One more round?", "See you!"
    ]
}

// MARK: - Controls

/// The family settings. Default: everything allowed, nothing locked.
public struct ParentalControls: Codable, Hashable, Sendable {
    /// A salted hash of the passcode; nil when Settings is not locked.
    public private(set) var passcodeHash: String?
    private var passcodeSalt: String = ""

    /// Most minutes of play a day; nil for no limit.
    public var dailyLimitMinutes: Int?
    /// A reminder to rest after this many minutes of one session.
    public var breakEveryMinutes: Int?
    public var quietHours: QuietHours?
    public var chat: ChatAllowance = .full
    /// Whether this iPad may open a room anyone nearby can join.
    public var allowPublicRooms = true
    /// Whether this iPad may join other people's rooms.
    public var allowJoiningRooms = true
    /// Most coins spent in the shop a day; nil for no limit.
    public var dailyCoinLimit: Int?
    /// Games tagged "horror" are left out of the lists.
    public var hideScaryGames = false

    public init() {}

    public var isLocked: Bool { passcodeHash != nil }

    /// 4 to 8 digits.
    public static func isValidPasscode(_ code: String) -> Bool {
        (4...8).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Sets (or with nil, removes) the passcode.
    @discardableResult
    public mutating func setPasscode(_ code: String?) -> Bool {
        guard let code else {
            passcodeHash = nil
            return true
        }
        guard Self.isValidPasscode(code) else { return false }
        passcodeSalt = UUID().uuidString
        passcodeHash = Self.hash(code, salt: passcodeSalt)
        return true
    }

    public func accepts(_ code: String) -> Bool {
        guard let passcodeHash else { return true }
        return Self.hash(code, salt: passcodeSalt) == passcodeHash
    }

    /// Enough that the code is not sitting in the settings file in plain
    /// text for a curious child to read. (A four-digit code is no defence
    /// against a computer, and is not meant to be.)
    static func hash(_ code: String, salt: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for _ in 0..<500 {
            for byte in (salt + ":" + code).utf8 { h = (h ^ UInt64(byte)) &* 0x1000_0000_01b3 }
        }
        return String(h, radix: 16)
    }
}

// MARK: - Play time

/// How long was played, per day and per game. Kept for sixty days.
public struct PlaytimeLog: Codable, Hashable, Sendable {

    public struct Day: Codable, Hashable, Sendable, Identifiable {
        /// "2026-09-26", in the iPad's own time zone.
        public let date: String
        public var seconds: Double = 0
        /// Seconds per game, by name.
        public var games: [String: Double] = [:]
        public var id: String { date }

        public var minutes: Int { Int(seconds / 60) }
    }

    public private(set) var days: [Day] = []
    /// Every game ever played here: seconds and times started.
    public private(set) var totalSeconds: [String: Double] = [:]
    public private(set) var timesPlayed: [String: Int] = [:]

    public static let keptDays = 60

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public mutating func startedPlaying(_ game: String) {
        timesPlayed[game, default: 0] += 1
    }

    public mutating func add(seconds: Double, game: String, at date: Date, calendar: Calendar = .current) {
        guard seconds.isFinite, seconds > 0 else { return }
        // A single report longer than an hour is the iPad having slept.
        let counted = min(seconds, 3600)
        let key = Self.dayKey(date, calendar: calendar)
        if let i = days.firstIndex(where: { $0.date == key }) {
            days[i].seconds += counted
            days[i].games[game, default: 0] += counted
        } else {
            var day = Day(date: key)
            day.seconds = counted
            day.games[game] = counted
            days.append(day)
            days.sort { $0.date < $1.date }
            if days.count > Self.keptDays { days.removeFirst(days.count - Self.keptDays) }
        }
        totalSeconds[game, default: 0] += counted
    }

    public func seconds(on date: Date, calendar: Calendar = .current) -> Double {
        let key = Self.dayKey(date, calendar: calendar)
        return days.first { $0.date == key }?.seconds ?? 0
    }

    /// The last `count` days, newest first, with empty days filled in.
    public func recent(_ count: Int, until date: Date = Date(), calendar: Calendar = .current) -> [Day] {
        (0..<max(0, count)).compactMap { back -> Day? in
            guard let day = calendar.date(byAdding: .day, value: -back, to: date) else { return nil }
            let key = Self.dayKey(day, calendar: calendar)
            return days.first { $0.date == key } ?? Day(date: key)
        }
    }

    /// Games by all-time play, most first.
    public var favourites: [(game: String, seconds: Double, times: Int)] {
        totalSeconds.map { ($0.key, $0.value, timesPlayed[$0.key] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    public mutating func removeAll() {
        self = PlaytimeLog()
    }
}

// MARK: - May we play?

public enum PlayGate {

    public enum Verdict: Equatable, Sendable {
        case allowed
        /// Today's minutes are used up.
        case dailyLimitReached(minutes: Int)
        /// Bedtime or school time, until the given clock time.
        case quietHours(until: String)
    }

    public static func verdict(_ controls: ParentalControls, log: PlaytimeLog, now: Date = Date(),
                               calendar: Calendar = .current) -> Verdict {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if let quiet = controls.quietHours, quiet.contains(minuteOfDay: minute) {
            return .quietHours(until: QuietHours.clock(quiet.end))
        }
        if let limit = controls.dailyLimitMinutes, log.seconds(on: now, calendar: calendar) >= Double(limit * 60) {
            return .dailyLimitReached(minutes: limit)
        }
        return .allowed
    }

    /// Minutes left today, or nil for no limit.
    public static func minutesLeft(_ controls: ParentalControls, log: PlaytimeLog, now: Date = Date(),
                                   calendar: Calendar = .current) -> Int? {
        guard let limit = controls.dailyLimitMinutes else { return nil }
        return max(0, limit - Int(log.seconds(on: now, calendar: calendar) / 60))
    }

    /// Whether a rest reminder is due, `sessionSeconds` into play, the last
    /// one having been shown at `lastReminder` seconds.
    public static func breakDue(_ controls: ParentalControls, sessionSeconds: Double, lastReminder: Double) -> Bool {
        guard let every = controls.breakEveryMinutes, every > 0 else { return false }
        return sessionSeconds - lastReminder >= Double(every * 60)
    }

    public static func message(for verdict: Verdict) -> String? {
        switch verdict {
        case .allowed: return nil
        case let .dailyLimitReached(minutes): return L("That's today's {} minutes of play. See you tomorrow!", minutes)
        case let .quietHours(until): return L("It's quiet time. Games open again at {}.", until)
        }
    }
}

// MARK: - Coins

/// Every coin in and out, newest first, for the history screen and the daily
/// spending limit.
public struct CoinLedger: Codable, Hashable, Sendable {

    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        /// Positive earned, negative spent.
        public let amount: Int
        public let reason: String
    }

    public private(set) var entries: [Entry] = []
    public static let keptEntries = 300

    public init() {}

    public mutating func record(_ amount: Int, reason: String, at date: Date = Date()) {
        guard amount != 0 else { return }
        entries.insert(Entry(id: UUID(), date: date, amount: amount, reason: String(reason.prefix(80))), at: 0)
        if entries.count > Self.keptEntries { entries.removeLast(entries.count - Self.keptEntries) }
    }

    public func spent(on date: Date, calendar: Calendar = .current) -> Int {
        let key = PlaytimeLog.dayKey(date, calendar: calendar)
        return entries.filter { $0.amount < 0 && PlaytimeLog.dayKey($0.date, calendar: calendar) == key }.reduce(0) { $0 - $1.amount }
    }

    /// Whether spending `price` now keeps within today's limit.
    public func allows(spending price: Int, limit: Int?, on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let limit else { return true }
        return spent(on: date, calendar: calendar) + price <= limit
    }
}

// MARK: - Names

public extension ChatModerator {
    /// A display name with a blocked word in it becomes "Player" — for
    /// everyone, whatever the sender's own filter setting.
    func cleanName(_ name: String) -> String {
        ChatModerator(isFilterEnabled: true).filter(name).wasFiltered ? "Player" : name
    }
}
