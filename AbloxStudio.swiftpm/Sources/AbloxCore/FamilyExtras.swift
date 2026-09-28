import Foundation

// Settings, family and access, the second round: a weekend limit, days
// off, extra time for today, only games a grown-up chose (or none they
// hid), asking before big purchases, a note on the menu, presets by age, a
// record of changes; and for everyone, bold text, less motion, sound
// captions, slower movement and "what's around me". All rules, no screens:
// tested here.

// MARK: - More family controls

public struct FamilyExtras: Codable, Hashable, Sendable {
    /// Minutes a day on Saturdays and Sundays; nil uses the everyday limit.
    public var weekendLimitMinutes: Int?
    /// Weekdays with no play at all (1 is Sunday … 7 is Saturday).
    public var daysOff: Set<Int> = []
    /// Extra minutes given for one day only.
    public var extraMinutes = 0
    public var extraDay: String?
    /// Only the games in `chosenGames` show and play.
    public var onlyChosenGames = false
    public var chosenGames: Set<String> = []
    /// Games a grown-up put away.
    public var hiddenGames: Set<String> = []
    /// Shop items dearer than this need the passcode.
    public var askAbove: Int?
    /// A note on the main menu: "Dinner at six!"
    public var note: String?
    /// A reminder of the passcode, for the grown-up.
    public var passcodeHint: String?

    /// Minutes of play left before a warning is due: at 10 and at 5.
    public static let warningMinutes = [10, 5]
    /// Every so many minutes: look far away for twenty seconds.
    public var eyeRestMinutes: Int?
    /// All play stops now, until a grown-up turns this off.
    public var pausedNow = false
    public var picturesAllowed = true
    public var shopAllowed = true
    /// The Worlds tab, for building.
    public var buildingAllowed = true
    /// Only friends' lines in chat (the game's own always show).
    public var chatFriendsOnly = false
    public var whispersAllowed = true
    /// Quiet hours on school days (Monday to Friday) only.
    public var quietSchoolDaysOnly = false

    public static let maximumNoteLength = 120

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekendLimitMinutes = try? c.decodeIfPresent(Int.self, forKey: .weekendLimitMinutes)
        daysOff = ((try? c.decodeIfPresent(Set<Int>.self, forKey: .daysOff)) ?? []).filter { (1...7).contains($0) }
        extraMinutes = Swift.max(0, (try? c.decodeIfPresent(Int.self, forKey: .extraMinutes)) ?? 0)
        extraDay = try? c.decodeIfPresent(String.self, forKey: .extraDay)
        onlyChosenGames = (try? c.decodeIfPresent(Bool.self, forKey: .onlyChosenGames)) ?? false
        chosenGames = (try? c.decodeIfPresent(Set<String>.self, forKey: .chosenGames)) ?? []
        hiddenGames = (try? c.decodeIfPresent(Set<String>.self, forKey: .hiddenGames)) ?? []
        askAbove = try? c.decodeIfPresent(Int.self, forKey: .askAbove)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        passcodeHint = try? c.decodeIfPresent(String.self, forKey: .passcodeHint)
        eyeRestMinutes = try? c.decodeIfPresent(Int.self, forKey: .eyeRestMinutes)
        pausedNow = (try? c.decodeIfPresent(Bool.self, forKey: .pausedNow)) ?? false
        picturesAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .picturesAllowed)) ?? true
        shopAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .shopAllowed)) ?? true
        buildingAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .buildingAllowed)) ?? true
        chatFriendsOnly = (try? c.decodeIfPresent(Bool.self, forKey: .chatFriendsOnly)) ?? false
        whispersAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .whispersAllowed)) ?? true
        quietSchoolDaysOnly = (try? c.decodeIfPresent(Bool.self, forKey: .quietSchoolDaysOnly)) ?? false
    }

    /// Whether a game may be shown and played.
    public func allows(game id: String) -> Bool {
        !hiddenGames.contains(id) && (!onlyChosenGames || chosenGames.contains(id))
    }

    /// Whether buying at `price` needs the passcode.
    public func needsPermission(price: Int) -> Bool {
        askAbove.map { price > $0 } ?? false
    }

    /// Extra minutes for `day`, if given for it.
    public func extra(on day: String) -> Int {
        extraDay == day ? extraMinutes : 0
    }

    /// Gives extra minutes today, on top of any already given today.
    public mutating func giveExtra(_ minutes: Int, on day: String) {
        extraMinutes = (extraDay == day ? extraMinutes : 0) + Swift.max(0, minutes)
        extraDay = day
    }

    /// Weekday names for the days-off picker, Sunday first.
    public static func weekdayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "\(weekday)"
    }
}

public extension ParentalControls {
    /// The second round's controls; always there, even in settings saved
    /// before they existed.
    var family: FamilyExtras {
        get { extras ?? FamilyExtras() }
        set { extras = newValue }
    }

    /// Today's limit in minutes, with the weekend's own and any extra time.
    func limit(on date: Date, calendar: Calendar = .current) -> Int? {
        let weekend = calendar.isDateInWeekend(date)
        guard let base = (weekend ? family.weekendLimitMinutes ?? dailyLimitMinutes : dailyLimitMinutes) else { return nil }
        return base + family.extra(on: PlaytimeLog.dayKey(date, calendar: calendar))
    }

    /// Whether today is a day off.
    func isDayOff(_ date: Date, calendar: Calendar = .current) -> Bool {
        family.daysOff.contains(calendar.component(.weekday, from: date))
    }

    /// Whether quiet hours apply today at all.
    func quietHoursApply(on date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHours != nil else { return false }
        return !family.quietSchoolDaysOnly || !calendar.isDateInWeekend(date)
    }

    /// What changed between two sets of controls, in words, for the log.
    func changes(from old: ParentalControls) -> [String] {
        var said: [String] = []
        func minutes(_ value: Int?) -> String { value.map { L("{} minutes", $0) } ?? L("no limit") }
        if dailyLimitMinutes != old.dailyLimitMinutes { said.append(L("Daily limit: {}", minutes(dailyLimitMinutes))) }
        if family.weekendLimitMinutes != old.family.weekendLimitMinutes {
            said.append(L("Weekend limit: {}", minutes(family.weekendLimitMinutes)))
        }
        if breakEveryMinutes != old.breakEveryMinutes { said.append(L("Rest reminder: {}", minutes(breakEveryMinutes))) }
        if quietHours != old.quietHours {
            said.append(quietHours.map { L("Quiet hours: {} to {}", QuietHours.clock($0.start), QuietHours.clock($0.end)) } ?? L("Quiet hours off"))
        }
        if chat != old.chat { said.append(L("Chat: {}", chat.displayName)) }
        if allowPublicRooms != old.allowPublicRooms { said.append(allowPublicRooms ? L("Public rooms allowed") : L("Public rooms not allowed")) }
        if allowJoiningRooms != old.allowJoiningRooms { said.append(allowJoiningRooms ? L("Joining rooms allowed") : L("Joining rooms not allowed")) }
        if dailyCoinLimit != old.dailyCoinLimit { said.append(L("Coin limit: {}", dailyCoinLimit.map(String.init) ?? L("none"))) }
        if hideScaryGames != old.hideScaryGames { said.append(hideScaryGames ? L("Scary games hidden") : L("Scary games shown")) }
        if family.daysOff != old.family.daysOff { said.append(L("Days off: {}", family.daysOff.count)) }
        if family.extra(on: family.extraDay ?? "") != old.family.extra(on: family.extraDay ?? ""), family.extraMinutes > 0 {
            said.append(L("Extra time today: {} minutes", family.extraMinutes))
        }
        if family.onlyChosenGames != old.family.onlyChosenGames || family.chosenGames != old.family.chosenGames {
            said.append(family.onlyChosenGames ? L("Only chosen games: {}", family.chosenGames.count) : L("All games allowed"))
        }
        if family.hiddenGames != old.family.hiddenGames { said.append(L("Games put away: {}", family.hiddenGames.count)) }
        if family.askAbove != old.family.askAbove {
            said.append(family.askAbove.map { L("Ask before buying over {} coins", $0) } ?? L("No asking before buying"))
        }
        if family.pausedNow != old.family.pausedNow { said.append(family.pausedNow ? L("All play paused") : L("Play allowed again")) }
        if family.picturesAllowed != old.family.picturesAllowed { said.append(family.picturesAllowed ? L("Pictures allowed") : L("No pictures")) }
        if family.shopAllowed != old.family.shopAllowed { said.append(family.shopAllowed ? L("Shop allowed") : L("Shop put away")) }
        if family.buildingAllowed != old.family.buildingAllowed { said.append(family.buildingAllowed ? L("Building allowed") : L("Building put away")) }
        if family.chatFriendsOnly != old.family.chatFriendsOnly { said.append(family.chatFriendsOnly ? L("Chat with friends only") : L("Chat with everyone")) }
        if family.whispersAllowed != old.family.whispersAllowed { said.append(family.whispersAllowed ? L("Whispers allowed") : L("No whispers")) }
        if family.quietSchoolDaysOnly != old.family.quietSchoolDaysOnly {
            said.append(family.quietSchoolDaysOnly ? L("Quiet hours on school days only") : L("Quiet hours every day"))
        }
        if isLocked != old.isLocked { said.append(isLocked ? L("Passcode set") : L("Passcode removed")) }
        return said
    }
}

/// Changes to the family settings, newest first, for a grown-up to look
/// back on.
public struct FamilyLog: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        public let text: String
    }

    public private(set) var entries: [Entry] = []
    public static let kept = 100

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = Array(((try? c.decodeIfPresent([Entry].self, forKey: .entries)) ?? []).prefix(Self.kept))
    }

    public mutating func record(_ changes: [String], at date: Date = Date()) {
        for text in changes.reversed() {
            entries.insert(Entry(id: UUID(), date: date, text: String(text.prefix(120))), at: 0)
        }
        if entries.count > Self.kept { entries.removeLast(entries.count - Self.kept) }
    }
}

/// Ready-made family settings for an age.
public enum AgePreset: String, CaseIterable, Sendable, Identifiable {
    case young, middle, older, teen

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .young: return L("Under 7")
        case .middle: return L("7 to 9")
        case .older: return L("10 to 12")
        case .teen: return L("13 and over")
        }
    }

    public var summary: String {
        switch self {
        case .young: return L("Ready-made phrases only, no public rooms, an hour a day, a rest every 20 minutes, no scary games.")
        case .middle: return L("Ready-made phrases only, 90 minutes a day, a rest every 30 minutes, no scary games.")
        case .older: return L("Typed chat with the strict filter, two hours a day, a rest every 45 minutes.")
        case .teen: return L("Everything on, with the word filter and a rest every hour.")
        }
    }

    /// Sets the controls this preset covers; the passcode is left alone.
    public func apply(to controls: inout ParentalControls) {
        switch self {
        case .young:
            controls.chat = .phrases
            controls.allowPublicRooms = false
            controls.allowJoiningRooms = true
            controls.dailyLimitMinutes = 60
            controls.breakEveryMinutes = 20
            controls.hideScaryGames = true
            controls.dailyCoinLimit = 200
            controls.quietHours = QuietHours(start: 20 * 60, end: 7 * 60)
            controls.strictChatFilter = true
        case .middle:
            controls.chat = .phrases
            controls.allowPublicRooms = true
            controls.allowJoiningRooms = true
            controls.dailyLimitMinutes = 90
            controls.breakEveryMinutes = 30
            controls.hideScaryGames = true
            controls.dailyCoinLimit = 400
            controls.quietHours = QuietHours(start: 21 * 60, end: 7 * 60)
            controls.strictChatFilter = true
        case .older:
            controls.chat = .full
            controls.allowPublicRooms = true
            controls.allowJoiningRooms = true
            controls.dailyLimitMinutes = 120
            controls.breakEveryMinutes = 45
            controls.hideScaryGames = false
            controls.dailyCoinLimit = nil
            controls.quietHours = QuietHours(start: 22 * 60, end: 6 * 60 + 30)
            controls.strictChatFilter = true
        case .teen:
            controls.chat = .full
            controls.allowPublicRooms = true
            controls.allowJoiningRooms = true
            controls.dailyLimitMinutes = nil
            controls.breakEveryMinutes = 60
            controls.hideScaryGames = false
            controls.dailyCoinLimit = nil
            controls.quietHours = nil
            controls.strictChatFilter = nil
        }
    }
}

// MARK: - For everyone: access

/// Ways to make Ablox easier to see, hear and play. One field of
/// `PlayPreferences`, read tolerantly.
public struct AccessOptions: Codable, Hashable, Sendable {
    /// Heavier text everywhere.
    public var boldText = false
    /// Menus without sliding and springing.
    public var reduceMotion = false
    /// Each tab's name read aloud when it opens.
    public var readTabsAloud = false
    /// Messages at the bottom of the play screen stay twice as long.
    public var longerMessages = false
    /// A tap felt, and the screen flashing, for important sounds.
    public var vibrateImportant = false
    public var flashImportant = false
    /// A word on screen for each sound a game makes.
    public var soundCaptions = false
    /// Walking and running at a gentler speed, times the usual.
    public var movementSpeed: Double = 1
    public static let movementRange: ClosedRange<Double> = 0.5...1
    /// Asks before leaving a game.
    public var confirmLeaving = false
    /// The menu tab that opens first.
    public var startTab: String?

    /// Whether the play screen needs to hear the game's sounds at all.
    public var hearsSounds: Bool { soundCaptions || vibrateImportant || flashImportant }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boldText = (try? c.decodeIfPresent(Bool.self, forKey: .boldText)) ?? false
        reduceMotion = (try? c.decodeIfPresent(Bool.self, forKey: .reduceMotion)) ?? false
        soundCaptions = (try? c.decodeIfPresent(Bool.self, forKey: .soundCaptions)) ?? false
        let speed = (try? c.decodeIfPresent(Double.self, forKey: .movementSpeed)) ?? 1
        movementSpeed = speed.isFinite ? Swift.min(Swift.max(speed, Self.movementRange.lowerBound), Self.movementRange.upperBound) : 1
        confirmLeaving = (try? c.decodeIfPresent(Bool.self, forKey: .confirmLeaving)) ?? false
        readTabsAloud = (try? c.decodeIfPresent(Bool.self, forKey: .readTabsAloud)) ?? false
        longerMessages = (try? c.decodeIfPresent(Bool.self, forKey: .longerMessages)) ?? false
        vibrateImportant = (try? c.decodeIfPresent(Bool.self, forKey: .vibrateImportant)) ?? false
        flashImportant = (try? c.decodeIfPresent(Bool.self, forKey: .flashImportant)) ?? false
        startTab = try? c.decodeIfPresent(String.self, forKey: .startTab)
    }
}

public extension SoundCue {
    /// A word for the sound, for sound captions.
    var caption: String {
        switch self {
        case .collect, .coin: return L("Collected")
        case .checkpoint: return L("Checkpoint")
        case .hurt: return L("Ouch")
        case .bounce, .jump: return L("Boing")
        case .teleport, .whoosh: return L("Whoosh")
        case .goal, .win: return L("Goal!")
        case .join: return L("Someone joined")
        case .leave: return L("Someone left")
        case .tick: return L("Tick")
        case .error: return L("Oops")
        case .shoot, .laser: return L("Zap")
        case .hit: return L("Hit")
        case .reload: return L("Reloading")
        case .defeat, .lose: return L("Knocked out")
        case .powerUp, .magic: return L("Power up")
        case .explosion: return L("Boom")
        case .splash: return L("Splash")
        case .door: return L("Door")
        case .click: return L("Click")
        case .pop: return L("Pop")
        case .bell: return L("Bell")
        case .alarm: return L("Alarm!")
        case .drum: return L("Drum")
        }
    }

    /// Worth a stronger flash, for players who cannot hear it.
    var isImportant: Bool {
        switch self {
        case .hurt, .alarm, .defeat, .explosion, .goal, .win: return true
        default: return false
        }
    }
}

// MARK: - What's around me

public enum SurroundingsReport {

    /// Where something is from someone facing `yaw`: "ahead", "to the left"…
    public static func direction(from position: Vec3, yaw: Float, to target: Vec3) -> String {
        let dx = target.x - position.x, dz = target.z - position.z
        guard dx * dx + dz * dz > 0.01 else { return L("right here") }
        // A body with yaw θ faces (sin θ, 0, −cos θ): 0 is −z, 90 is +x.
        // The target's bearing in the same terms; more is to the right.
        let angle = atan2(dx, -dz) * 180 / .pi
        let relative = normalizeDegrees(angle - yaw)
        switch relative {
        case -30...30: return L("ahead")
        case 30...80: return L("ahead to the right")
        case 80...130: return L("to the right")
        case -80 ... -30: return L("ahead to the left")
        case -130 ... -80: return L("to the left")
        default: return L("behind")
        }
    }

    /// A sentence about the nearest people, for VoiceOver.
    public static func describe(me: PlayerSnapshot, others: [PlayerSnapshot], limit: Int = 3) -> String {
        let near = others.filter { $0.peerID != me.peerID && !$0.isHidden }
            .map { ($0, $0.position.distance(to: me.position)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
        guard !near.isEmpty else { return L("Nobody else is nearby.") }
        let parts = near.map { person, distance in
            L("{}, {} metres {}", person.profile.displayName, Int(distance.rounded()),
              direction(from: me.position, yaw: me.yawDegrees, to: person.position))
        }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Settings: tips and moving them

public enum SettingsTips {
    public static var all: [String] {
        [
            L("Two taps on the look side of the screen put the camera behind you."),
            L("Settings → Play screen can add a compass, your speed and a run button."),
            L("Long-press a game to put it on a list of your own or give it stars."),
            L("Save phrases of your own in the chat, under Mine."),
            L("Photo mode has a timer and bursts of three."),
            L("Coins in the coin jar grow every week."),
            L("Swap one of today's missions for another on the Play tab."),
            L("Press K on a keyboard to see every shortcut."),
            L("Pin your best friends to the top of the friends list."),
            L("Heart your favourite pictures in the album to find them fast."),
            L("A game played alone pauses itself when you walk away."),
            L("Seasons bring extra coins and sales: look for the banner."),
            L("Hold a message in the chat to whisper back or add a friend."),
            L("Turn on words for sounds in Settings → Seeing and hearing.")
        ]
    }

    /// The same tip all day.
    public static func tip(on day: String) -> String {
        let tips = all
        return tips[Int(MissionBook.stableHash("tip:" + day) % UInt64(tips.count))]
    }
}

/// A player's own settings as a file, to set up another iPad the same way.
/// Only how the game looks and feels: never the family settings, coins or
/// friends.
public struct SettingsTransfer: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = SettingsTransfer.currentVersion
    public var app = "Ablox"
    public var preferences: PlayPreferences

    public init(preferences: PlayPreferences) {
        self.preferences = preferences
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Settings from a file; nil for something that is not an Ablox
    /// settings file or is from a newer version than this one reads.
    public static func read(_ data: Data) -> SettingsTransfer? {
        guard data.count < 1_000_000, let transfer = try? JSONDecoder().decode(SettingsTransfer.self, from: data),
              transfer.app == "Ablox", transfer.version <= currentVersion else { return nil }
        var clean = transfer
        clean.preferences.clamp()
        return clean
    }
}
