import Foundation

// Small things around playing: a timer a player sets for themselves, a
// month of play on a calendar, how the crosshair looks, and noticing when a
// friend starts playing nearby. All rules, no screens: tested here.

// MARK: - A timer of one's own

/// "Ten more minutes", set by the player from the pause menu. Separate from
/// the family's daily limit: this one is a promise to oneself, and ending it
/// only opens the pause menu.
public struct SelfTimer: Hashable, Sendable {
    public static let choices = [5, 10, 15, 30, 60]
    /// The warning comes this long before the end.
    public static let warningSeconds: Double = 60

    public enum Event: Equatable, Sendable {
        case none, warning, finished
    }

    public private(set) var endsAt: Date?
    private var warned = false

    public init() {}

    public var isRunning: Bool { endsAt != nil }

    public mutating func start(minutes: Int, now: Date = Date()) {
        endsAt = now.addingTimeInterval(Double(Swift.max(1, minutes)) * 60)
        warned = minutes * 60 <= Int(Self.warningSeconds)
    }

    public mutating func cancel() {
        endsAt = nil
        warned = false
    }

    /// Seconds left, rounded up; nil when no timer is set.
    public func remaining(now: Date = Date()) -> Int? {
        guard let endsAt else { return nil }
        return Swift.max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
    }

    /// Called now and then while playing: says once when a minute is left,
    /// and once when the time is up (which also stops the timer).
    public mutating func tick(now: Date = Date()) -> Event {
        guard let left = remaining(now: now) else { return .none }
        if left == 0 {
            cancel()
            return .finished
        }
        if !warned, Double(left) <= Self.warningSeconds {
            warned = true
            return .warning
        }
        return .none
    }

    /// "4:05".
    public static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - A month of play

/// The days of a month laid out in weeks, with how long was played on each,
/// for the calendar on the statistics screen.
public enum PlayCalendar {
    public struct Cell: Hashable, Sendable, Identifiable {
        /// 1…31; nil for the blanks before the first of the month.
        public let day: Int?
        public let minutes: Int
        public let isToday: Bool
        public let id: Int
    }

    /// Weeks start on the calendar's first weekday (Sunday in Japan, Monday
    /// in much of Europe).
    public static func cells(month date: Date, log: PlaytimeLog, today: Date = Date(), calendar: Calendar = .current) -> [Cell] {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let days = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        let todayKey = PlaytimeLog.dayKey(today, calendar: calendar)
        var cells = (0..<blanks).map { Cell(day: nil, minutes: 0, isToday: false, id: -1 - $0) }
        for day in days {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) else { continue }
            let key = PlaytimeLog.dayKey(date, calendar: calendar)
            cells.append(Cell(day: day, minutes: Int(log.seconds(on: date, calendar: calendar) / 60),
                              isToday: key == todayKey, id: day))
        }
        return cells
    }

    /// 0 (not played) to 3 (an hour or more), for how strongly to colour it.
    public static func level(minutes: Int) -> Int {
        switch minutes {
        case ..<1: return 0
        case ..<20: return 1
        case ..<60: return 2
        default: return 3
        }
    }

    /// Days played in the month and the minutes in all.
    public static func totals(_ cells: [Cell]) -> (days: Int, minutes: Int) {
        let played = cells.filter { $0.day != nil && $0.minutes > 0 }
        return (played.count, played.reduce(0) { $0 + $1.minutes })
    }

    /// "September 2026" / "2026年9月".
    public static func title(month date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 1
        if Localization.language == .japanese { return "\(year)年\(month)月" }
        let names = ["January", "February", "March", "April", "May", "June", "July",
                     "August", "September", "October", "November", "December"]
        return "\(names[(month - 1) % 12]) \(year)"
    }
}

// MARK: - The crosshair

/// How the aiming mark in the middle of the screen looks.
public enum CrosshairStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case plus, dot, circle, off
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .plus: return L("Plus")
        case .dot: return L("Dot")
        case .circle: return L("Ring")
        case .off: return L("Off")
        }
    }

    /// The SF Symbol drawn, nil for none.
    public var symbolName: String? {
        switch self {
        case .plus: return "plus"
        case .dot: return "circle.fill"
        case .circle: return "circle"
        case .off: return nil
        }
    }

    /// A dot is drawn small; the others at the usual size.
    public var pointSize: Double { self == .dot ? 8 : 22 }
}

/// The crosshair's colour: easy to see on most worlds.
public enum CrosshairColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case white, yellow, green, pink
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .white: return L("White")
        case .yellow: return L("Yellow")
        case .green: return L("Green")
        case .pink: return L("Pink")
        }
    }

    public var color: ColorRGBA {
        switch self {
        case .white: return ColorRGBA(r: 1, g: 1, b: 1)
        case .yellow: return ColorRGBA(r: 1, g: 0.86, b: 0.2)
        case .green: return ColorRGBA(r: 0.3, g: 1, b: 0.45)
        case .pink: return ColorRGBA(r: 1, g: 0.4, b: 0.75)
        }
    }
}

// MARK: - A friend starts playing nearby

/// Notices friends showing up in rooms nearby while the player is in the
/// menus, so the menu can say so once, with a Join button.
public struct FriendSightings: Hashable, Sendable {
    public struct Sighting: Hashable, Sendable {
        public let roomID: String
        public let friend: PeerID
    }

    /// Friends already announced in each room, so each is said only once.
    private var announced: [String: Set<PeerID>] = [:]

    public init() {}

    /// Friends newly seen in `rooms`, one per room at most. Rooms that have
    /// gone are forgotten, so a friend who leaves and comes back is
    /// announced again.
    public mutating func newlySeen(rooms: [(id: String, tag: RoomTag)], friends: [PeerID]) -> [Sighting] {
        let live = Set(rooms.map(\.id))
        announced = announced.filter { live.contains($0.key) }
        var found: [Sighting] = []
        for room in rooms {
            let already = announced[room.id] ?? []
            guard let friend = friends.first(where: { room.tag.contains($0) && !already.contains($0) }) else { continue }
            announced[room.id, default: []].insert(friend)
            found.append(Sighting(roomID: room.id, friend: friend))
        }
        return found
    }
}
