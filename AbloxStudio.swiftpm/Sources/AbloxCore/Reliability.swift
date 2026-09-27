import Foundation

// Keeping the app quick to open and easy to help: a cache of the world list,
// a log of problems that can be copied and sent in one tap, and notices
// published the same way as `update.json`.

// MARK: - The world list, without opening every world

/// What the world list needs to know about each file, kept so that opening
/// the app does not read every world in full. A file whose size and date
/// have not changed is listed from here; any other is read again.
public struct WorldListCache: Codable, Equatable, Sendable {

    public struct Item: Codable, Equatable, Sendable {
        public var byteCount: Int
        /// The file's modification time, seconds since 1970.
        public var fileModified: Double
        public var id: UUID
        public var name: String
        public var authorName: String
        /// The world's own "modified" time, seconds since 1970.
        public var modifiedAt: Double
        public var blockCount: Int

        public init(byteCount: Int, fileModified: Double, id: UUID, name: String, authorName: String,
                    modifiedAt: Double, blockCount: Int) {
            self.byteCount = byteCount
            self.fileModified = fileModified
            self.id = id
            self.name = name
            self.authorName = authorName
            self.modifiedAt = modifiedAt
            self.blockCount = blockCount
        }
    }

    /// Bumped when `Item` changes meaning, so an old cache is ignored.
    public static let currentVersion = 1

    public var version = WorldListCache.currentVersion
    /// By file name ("<id>.ablox", or "trash/<id>.ablox").
    public var items: [String: Item] = [:]

    public init() {}

    /// The cached item for a file, only when it is unchanged on disk.
    public func item(named name: String, byteCount: Int, fileModified: Double) -> Item? {
        guard version == Self.currentVersion, let item = items[name], item.byteCount == byteCount,
              abs(item.fileModified - fileModified) < 0.001 else { return nil }
        return item
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) -> WorldListCache {
        guard let cache = try? JSONDecoder().decode(WorldListCache.self, from: data), cache.version == currentVersion else {
            return WorldListCache()
        }
        return cache
    }
}

// MARK: - Problems, kept to send

/// Something that went wrong, kept so it can be sent to whoever is helping.
public struct ProblemReport: Codable, Hashable, Sendable, Identifiable {

    public enum Area: String, Codable, CaseIterable, Sendable {
        case crash, script, network, cloud, saving, catalogue, update, other

        public var displayName: String {
            switch self {
            case .crash: return L("Closed unexpectedly")
            case .script: return L("Script")
            case .network: return L("Playing together")
            case .cloud: return L("Internet")
            case .saving: return L("Saving")
            case .catalogue: return L("Game list")
            case .update: return L("Updates")
            case .other: return L("Other")
            }
        }

        public var symbolName: String {
            switch self {
            case .crash: return "exclamationmark.octagon.fill"
            case .script: return "curlybraces"
            case .network: return "wifi.exclamationmark"
            case .cloud: return "icloud.slash"
            case .saving: return "externaldrive.badge.exclamationmark"
            case .catalogue: return "square.grid.2x2"
            case .update: return "arrow.down.app"
            case .other: return "questionmark.circle"
            }
        }
    }

    public var id: UUID
    /// Seconds since 1970.
    public var time: Double
    public var area: Area
    public var message: String
    /// Where it happened: a world, a file, a screen.
    public var detail: String?
    /// How many times in a row the same thing happened.
    public var count: Int

    public init(id: UUID = UUID(), time: Double, area: Area, message: String, detail: String? = nil, count: Int = 1) {
        self.id = id
        self.time = time
        self.area = area
        self.message = message
        self.detail = detail
        self.count = count
    }
}

/// The last few hundred problems on this iPad, newest last.
public struct ProblemLog: Codable, Equatable, Sendable {

    public static let maximumReports = 200
    public static let maximumMessageLength = 1_500
    /// The same problem again within this many seconds is counted, not added.
    public static let repeatWindow: Double = 120

    public var reports: [ProblemReport] = []

    public init() {}

    /// Keeps a problem. Returns false when it only added to the count of the
    /// one before it.
    @discardableResult
    public mutating func add(_ area: ProblemReport.Area, _ message: String, detail: String? = nil, at time: Double) -> Bool {
        let text = Self.clean(message)
        guard !text.isEmpty else { return false }
        let place = detail.map(Self.clean).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        if let last = reports.indices.last, reports[last].area == area, reports[last].message == text,
           reports[last].detail == place, time - reports[last].time < Self.repeatWindow {
            reports[last].count += 1
            reports[last].time = time
            return false
        }
        reports.append(ProblemReport(time: time, area: area, message: text, detail: place))
        if reports.count > Self.maximumReports { reports.removeFirst(reports.count - Self.maximumReports) }
        return true
    }

    private static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumMessageLength))
    }

    /// The report to paste into a message: what the app is, then the newest
    /// problems first.
    public func text(app: String, version: String, device: String, system: String, last count: Int = 40,
                     now: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["\(app) \(version) — \(device), \(system)",
                     "Report made \(formatter.string(from: Date(timeIntervalSince1970: now)))", ""]
        let recent = reports.suffix(count).reversed()
        if recent.isEmpty {
            lines.append("No problems recorded.")
        }
        for report in recent {
            var line = "[\(formatter.string(from: Date(timeIntervalSince1970: report.time)))] \(report.area.rawValue)"
            if report.count > 1 { line += " ×\(report.count)" }
            if let detail = report.detail { line += " (\(detail))" }
            lines.append(line)
            lines.append("  " + report.message.replacingOccurrences(of: "\n", with: "\n  "))
        }
        return lines.joined(separator: "\n")
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) -> ProblemLog {
        (try? JSONDecoder().decode(ProblemLog.self, from: data)) ?? ProblemLog()
    }
}

/// What the crash catcher writes as the app goes down, and how to read it.
///
/// Written from a signal handler, so it is plain text made in advance:
/// "ablox-crash <signal>". What the player was doing is kept separately,
/// before anything goes wrong.
public enum CrashMarker {

    public static let prefix = "ablox-crash "

    /// The signals caught: a Swift trap (force-unwrapping nil, an index out of
    /// range), a bad memory access, an abort.
    public static let signals: [Int32] = [4, 5, 6, 7, 8, 10, 11]

    public static func line(for signal: Int32) -> String {
        prefix + String(signal) + "\n"
    }

    /// The signal in a marker file, if one was written.
    public static func signal(in text: String) -> Int32? {
        for line in text.split(separator: "\n") where line.hasPrefix(prefix) {
            if let number = Int32(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)) { return number }
        }
        return nil
    }

    /// What a signal means, in words.
    public static func describe(_ signal: Int32) -> String {
        switch signal {
        case 4: return L("an illegal instruction (SIGILL)")
        case 5: return L("a Swift runtime error, such as a missing value or an index out of range (SIGTRAP)")
        case 6: return L("an abort (SIGABRT)")
        case 7, 10: return L("a bad memory access (SIGBUS)")
        case 8: return L("a number error, such as dividing by zero (SIGFPE)")
        case 11: return L("a bad memory access (SIGSEGV)")
        default: return "signal \(signal)"
        }
    }

    /// The problem to keep after a run that ended without saying goodbye.
    public static func report(signal: Int32?, doing: String?) -> String {
        var text: String
        if let signal {
            text = L("Ablox crashed last time: {}.", describe(signal))
        } else {
            text = L("Ablox closed unexpectedly last time. It may have run out of memory, or been stopped from Swift Playgrounds.")
        }
        if let doing, !doing.isEmpty {
            text += " " + L("It was: {}", doing)
        }
        return text
    }
}

// MARK: - Notices

/// A notice published beside `update.json` (`notices.json`) and shown on the
/// main menu: an event, a fix to know about, a server being down.
public struct AppNotice: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case info, event, warning
    }

    public var id: String
    public var kind: Kind
    /// By language ("en", "ja"); English when the language is missing.
    public var title: [String: String]
    public var body: [String: String]
    /// "2026-09-27" — shown from this day…
    public var from: String?
    /// …until the end of this one.
    public var until: String?
    /// Only for these versions of the app.
    public var minimumVersion: AppVersion?
    public var maximumVersion: AppVersion?
    /// "Ablox" or "Ablox Studio"; nil for both.
    public var app: String?

    public init(id: String, kind: Kind = .info, title: [String: String], body: [String: String], from: String? = nil,
                until: String? = nil, minimumVersion: AppVersion? = nil, maximumVersion: AppVersion? = nil, app: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.from = from
        self.until = until
        self.minimumVersion = minimumVersion
        self.maximumVersion = maximumVersion
        self.app = app
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, body, from, until, app
        case minimumVersion = "minVersion"
        case maximumVersion = "maxVersion"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .info
        title = try c.decode([String: String].self, forKey: .title)
        body = (try? c.decodeIfPresent([String: String].self, forKey: .body)) ?? [:]
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        until = try? c.decodeIfPresent(String.self, forKey: .until)
        minimumVersion = try? c.decodeIfPresent(AppVersion.self, forKey: .minimumVersion)
        maximumVersion = try? c.decodeIfPresent(AppVersion.self, forKey: .maximumVersion)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
    }

    public func title(in language: Language) -> String {
        title[language.rawValue] ?? title["en"] ?? title.values.sorted().first ?? ""
    }

    public func body(in language: Language) -> String {
        body[language.rawValue] ?? body["en"] ?? body.values.sorted().first ?? ""
    }
}

public enum NoticeBoard {

    public enum Limits {
        public static let maximumBytes = 64 * 1024
        public static let maximumNotices = 20
        public static let maximumTitleLength = 120
        public static let maximumBodyLength = 1_200
    }

    /// How often the menu looks for new notices.
    public static let checkInterval: TimeInterval = 3 * 60 * 60

    private struct File: Decodable {
        var notices: [AppNotice]
    }

    /// The notices in a `notices.json`, keeping only well-formed ones.
    public static func decode(_ data: Data) -> [AppNotice]? {
        guard data.count <= Limits.maximumBytes, let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var seen = Set<String>()
        return file.notices.prefix(Limits.maximumNotices).filter { notice in
            let id = notice.id.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, id.count <= 80, !seen.contains(id), !notice.title(in: .english).isEmpty,
                  notice.title.values.allSatisfy({ $0.count <= Limits.maximumTitleLength }),
                  notice.body.values.allSatisfy({ $0.count <= Limits.maximumBodyLength }) else { return false }
            seen.insert(id)
            return true
        }
    }

    /// Those to show now to this app and version, leaving out dismissed ones.
    public static func active(_ notices: [AppNotice], app: String, version: AppVersion?, today: String,
                              dismissed: Set<String>) -> [AppNotice] {
        notices.filter { notice in
            if dismissed.contains(notice.id) { return false }
            if let only = notice.app, only != app { return false }
            if let from = notice.from, today < from { return false }
            if let until = notice.until, today > until { return false }
            if let version {
                if let minimum = notice.minimumVersion, version < minimum { return false }
                if let maximum = notice.maximumVersion, version > maximum { return false }
            }
            return true
        }
    }

    /// "2026-09-27" for a date, in the iPad's own time zone.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
}
