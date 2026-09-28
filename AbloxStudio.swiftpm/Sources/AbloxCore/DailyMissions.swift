import Foundation

// Things to aim for between games: three small missions a day, a picture of
// how the last game went, and saving up for something on the wishlist. All
// rules, no screens: tested here.

// MARK: - Today's missions

/// What a mission asks for.
public enum MissionKind: String, Codable, CaseIterable, Sendable {
    case playMinutes, differentGames, earnCoins, takePicture, useEmote, playWithOthers, finishRound

    /// "Play for 15 minutes", with the target filled in.
    public func title(_ target: Int) -> String {
        switch self {
        case .playMinutes: return L("Play for {} minutes", target)
        case .differentGames: return L("Play {} different games", target)
        case .earnCoins: return L("Earn {} coins in games", target)
        case .takePicture: return target == 1 ? L("Take a picture in a game") : L("Take {} pictures in games", target)
        case .useEmote: return L("Use {} emotes", target)
        case .playWithOthers: return L("Play with someone else")
        case .finishRound: return target == 1 ? L("Finish a round") : L("Finish {} rounds", target)
        }
    }

    /// How to do it, for a small child.
    public var hint: String {
        switch self {
        case .playMinutes: return L("Any game counts, alone or with friends.")
        case .differentGames: return L("Try something new from the Games tab.")
        case .earnCoins: return L("Score points and finish rounds.")
        case .takePicture: return L("Tap the camera button while playing.")
        case .useEmote: return L("Tap the smiley face while playing.")
        case .playWithOthers: return L("Host a room or join a friend's.")
        case .finishRound: return L("Reach the end of a game's round.")
        }
    }

    public var symbolName: String {
        switch self {
        case .playMinutes: return "clock.fill"
        case .differentGames: return "square.grid.2x2.fill"
        case .earnCoins: return "bitcoinsign.circle.fill"
        case .takePicture: return "camera.fill"
        case .useEmote: return "hand.wave.fill"
        case .playWithOthers: return "person.2.fill"
        case .finishRound: return "flag.checkered"
        }
    }
}

/// One of today's missions.
public struct Mission: Hashable, Sendable, Identifiable {
    public let kind: MissionKind
    public let target: Int
    public let reward: Int
    public var id: String { kind.rawValue }
    public var title: String { kind.title(target) }
}

/// Today's three missions, how far along they are, and which rewards have
/// been taken. A new day starts afresh.
///
/// The missions come from the date alone, so they are the same all day,
/// after a relaunch too, and there is nothing to store about which were
/// picked.
public struct MissionBook: Codable, Hashable, Sendable {
    public private(set) var day = ""
    /// Progress by kind. Play time is kept in seconds, the rest as counts.
    public private(set) var counts: [String: Int] = [:]
    /// Games played today, for "different games".
    public private(set) var games: [String] = []
    public private(set) var claimed: Set<String> = []
    /// Today's swap, if one was made: the kind given up and the kind taken
    /// on. Optional so books saved before swapping existed still load.
    public private(set) var swapped: [String: String]?

    public static let missionsPerDay = 3
    /// For finishing all of a day's missions.
    public static let allDoneBonus = 40

    public init() {}

    /// The same three for everyone on the same day: always some play time,
    /// then two others.
    public static func missions(for day: String) -> [Mission] {
        var seed = stableHash(day)
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let minutes = [10, 15, 20][next(3)]
        var missions = [Mission(kind: .playMinutes, target: minutes, reward: 10 + minutes)]
        var others: [MissionKind] = [.differentGames, .earnCoins, .takePicture, .useEmote, .playWithOthers, .finishRound]
        while missions.count < missionsPerDay, !others.isEmpty {
            let kind = others.remove(at: next(others.count))
            let target: Int
            let reward: Int
            switch kind {
            case .differentGames: target = [2, 3][next(2)]; reward = 10 + 8 * target
            case .earnCoins: target = [30, 50, 80][next(3)]; reward = 10 + target / 5
            case .takePicture: target = 1; reward = 15
            case .useEmote: target = 3; reward = 15
            case .playWithOthers: target = 1; reward = 30
            case .finishRound: target = [1, 2][next(2)]; reward = 5 + 15 * target
            case .playMinutes: target = 10; reward = 20
            }
            missions.append(Mission(kind: kind, target: target, reward: reward))
        }
        return missions
    }

    /// FNV-1a: the same on every iPad and every launch, which `hashValue`
    /// is not.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public func missions(on day: String) -> [Mission] {
        let base = Self.missions(for: day)
        guard day == self.day, let swapped, !swapped.isEmpty else { return base }
        return base.map { mission in
            guard let raw = swapped[mission.kind.rawValue], let kind = MissionKind(rawValue: raw) else { return mission }
            return Self.standard(kind)
        }
    }

    /// A mission of a kind at its usual size, for a swap.
    public static func standard(_ kind: MissionKind) -> Mission {
        switch kind {
        case .playMinutes: return Mission(kind: kind, target: 10, reward: 20)
        case .differentGames: return Mission(kind: kind, target: 2, reward: 26)
        case .earnCoins: return Mission(kind: kind, target: 50, reward: 20)
        case .takePicture: return Mission(kind: kind, target: 1, reward: 15)
        case .useEmote: return Mission(kind: kind, target: 3, reward: 15)
        case .playWithOthers: return Mission(kind: kind, target: 1, reward: 30)
        case .finishRound: return Mission(kind: kind, target: 1, reward: 20)
        }
    }

    /// One swap a day, for a mission not already done or taken.
    public func canSwap(_ mission: Mission, on day: String) -> Bool {
        let unused = day != self.day || (swapped?.isEmpty ?? true)
        return unused && mission.kind != .playMinutes && !isDone(mission, on: day) && !isClaimed(mission, on: day)
    }

    /// Swaps a mission for another kind not already among today's; nil
    /// when it cannot be swapped.
    @discardableResult
    public mutating func swap(_ mission: Mission, on day: String) -> Mission? {
        roll(to: day)
        guard canSwap(mission, on: day) else { return nil }
        let current = Set(missions(on: day).map(\.kind))
        let choices = MissionKind.allCases.filter { !current.contains($0) && $0 != .playMinutes }
        guard !choices.isEmpty else { return nil }
        let kind = choices[Int(Self.stableHash("swap:" + day + mission.kind.rawValue) % UInt64(choices.count))]
        swapped = [mission.kind.rawValue: kind.rawValue]
        return Self.standard(kind)
    }

    public func allDone(on day: String) -> Bool {
        missions(on: day).allSatisfy { isDone($0, on: day) }
    }

    public func isAllDoneBonusWaiting(on day: String) -> Bool {
        allDone(on: day) && !(day == self.day && claimed.contains("all"))
    }

    /// The bonus for finishing every mission today, once.
    public mutating func claimAllDoneBonus(on day: String) -> Int? {
        roll(to: day)
        guard allDone(on: day), !claimed.contains("all") else { return nil }
        claimed.insert("all")
        return Self.allDoneBonus
    }

    /// Clears yesterday's progress when the day has changed.
    public mutating func roll(to day: String) {
        guard day != self.day else { return }
        self.day = day
        counts = [:]
        games = []
        claimed = []
        swapped = nil
    }

    public mutating func record(_ kind: MissionKind, amount: Int = 1, on day: String) {
        roll(to: day)
        guard amount > 0 else { return }
        counts[kind.rawValue, default: 0] += amount
    }

    /// A game started today; only the first time each counts.
    public mutating func played(game: String, on day: String) {
        roll(to: day)
        guard !game.isEmpty, !games.contains(game) else { return }
        games.append(game)
        if games.count > 20 { games.removeFirst(games.count - 20) }
    }

    /// How far along, in the mission's own unit (minutes for play time).
    public func progress(of mission: Mission, on day: String) -> Int {
        guard day == self.day else { return 0 }
        switch mission.kind {
        case .playMinutes: return (counts[mission.kind.rawValue] ?? 0) / 60
        case .differentGames: return games.count
        default: return counts[mission.kind.rawValue] ?? 0
        }
    }

    public func isDone(_ mission: Mission, on day: String) -> Bool {
        progress(of: mission, on: day) >= mission.target
    }

    public func isClaimed(_ mission: Mission, on day: String) -> Bool {
        day == self.day && claimed.contains(mission.id)
    }

    /// The reward, once: nil before the mission is done or after it was taken.
    public mutating func claim(_ mission: Mission, on day: String) -> Int? {
        roll(to: day)
        guard isDone(mission, on: day), !claimed.contains(mission.id) else { return nil }
        claimed.insert(mission.id)
        return mission.reward
    }

    /// Done and not yet taken, for a badge on the menu.
    public func waitingRewards(on day: String) -> Int {
        missions(on: day).filter { isDone($0, on: day) && !isClaimed($0, on: day) }.count
    }

    /// Which of today's are done, for the summary after a game.
    public func done(on day: String) -> Set<String> {
        Set(missions(on: day).filter { isDone($0, on: day) }.map(\.id))
    }
}

// MARK: - After a game

/// How a game went, for the card shown on the way back to the menu.
public struct SessionSummary: Hashable, Sendable {
    /// What is worth comparing, taken before and after.
    public struct Snapshot: Hashable, Sendable {
        public var at: Date
        public var lifetimeCoins: Int
        public var missionsDone: Set<String>
        public var badges: Set<String>

        public init(at: Date = Date(), lifetimeCoins: Int, missionsDone: Set<String>, badges: Set<String>) {
            self.at = at
            self.lifetimeCoins = lifetimeCoins
            self.missionsDone = missionsDone
            self.badges = badges
        }
    }

    public var game: String
    public var seconds: Double
    public var coins: Int
    public var missionsDone: Int
    /// Newly earned badges, by id.
    public var badges: [String]

    /// A peek in and straight out again is not worth a card.
    public static let minimumSeconds: Double = 30

    public init(game: String, before: Snapshot, after: Snapshot) {
        self.game = game
        seconds = Swift.max(0, after.at.timeIntervalSince(before.at))
        coins = Swift.max(0, after.lifetimeCoins - before.lifetimeCoins)
        missionsDone = after.missionsDone.subtracting(before.missionsDone).count
        badges = after.badges.subtracting(before.badges).sorted()
    }

    public var isWorthShowing: Bool {
        seconds >= Self.minimumSeconds || coins > 0 || !badges.isEmpty
    }

    /// "12 min" or "45 s".
    public var durationText: String {
        seconds >= 60 ? L("{} min", Int(seconds / 60)) : L("{} s", Int(seconds))
    }
}

// MARK: - Saving up

/// Saving for one thing on the wishlist.
public enum SavingsGoal {
    /// 0…1 of the way there.
    public static func progress(balance: Int, price: Int) -> Double {
        guard price > 0 else { return 1 }
        return Swift.min(1, Swift.max(0, Double(balance) / Double(price)))
    }

    /// Coins still needed; 0 once there are enough.
    public static func remaining(balance: Int, price: Int) -> Int {
        Swift.max(0, price - balance)
    }

    /// Roughly how many more days, earning `perDay` a day.
    public static func daysToGo(balance: Int, price: Int, perDay: Double) -> Int? {
        let left = remaining(balance: balance, price: price)
        guard left > 0 else { return 0 }
        guard perDay >= 1 else { return nil }
        return Int((Double(left) / perDay).rounded(.up))
    }

    /// Roughly how many more rounds, at what the last ones paid on average.
    public static func roundsToGo(balance: Int, price: Int, averagePerRound: Double) -> Int? {
        let left = remaining(balance: balance, price: price)
        guard left > 0 else { return 0 }
        guard averagePerRound >= 1 else { return nil }
        return Int((Double(left) / averagePerRound).rounded(.up))
    }
}
