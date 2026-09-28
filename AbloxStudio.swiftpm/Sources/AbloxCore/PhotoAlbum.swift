import Foundation

// Pictures and clips, the second round: what a file in the album is (which
// game, when), favourites and captions, the album grouped by day or by
// game, and photo mode's choices — timer, burst, grid, shape, frame, stamp.
// All rules, no screens: tested here. The screens are UI/MainMenu/AlbumViews
// .swift and UI/Game/PhotoExtras.swift.

// MARK: - A file in the album

/// One picture or clip in the album, from its file name ("Tower Run
/// 2026-09-28 10.20.30.png", as `ScreenshotStore` writes it).
public struct AlbumEntry: Hashable, Sendable, Identifiable {
    /// The file name, which is also how notes about it are kept.
    public let id: String
    public let game: String
    public let date: Date
    public let isClip: Bool
    public let bytes: Int

    public init(id: String, game: String, date: Date, isClip: Bool, bytes: Int = 0) {
        self.id = id
        self.game = game
        self.date = date
        self.isClip = isClip
        self.bytes = bytes
    }

    public static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg"]
    public static let clipExtensions: Set<String> = ["mp4", "mov"]

    /// What a file name says; nil for a file that is neither a picture nor
    /// a clip. A name without a date (from an older version, or renamed in
    /// Files) keeps `fallbackDate`.
    public static func parse(_ fileName: String, bytes: Int = 0, fallbackDate: Date = .distantPast) -> AlbumEntry? {
        let dot = fileName.lastIndex(of: ".")
        let ext = dot.map { String(fileName[fileName.index(after: $0)...]).lowercased() } ?? ""
        let isClip = clipExtensions.contains(ext)
        guard isClip || pictureExtensions.contains(ext) else { return nil }
        let stem = dot.map { String(fileName[..<$0]) } ?? fileName
        // The last 19 characters are the date when there is one.
        if stem.count >= 20 {
            let dateText = String(stem.suffix(19))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            if let date = formatter.date(from: dateText) {
                let game = String(stem.dropLast(19)).trimmingCharacters(in: .whitespaces)
                return AlbumEntry(id: fileName, game: game, date: date, isClip: isClip, bytes: bytes)
            }
        }
        return AlbumEntry(id: fileName, game: stem, date: fallbackDate, isClip: isClip, bytes: bytes)
    }
}

// MARK: - Notes on pictures

/// Favourite pictures and their captions, by file name.
public struct AlbumNotes: Codable, Hashable, Sendable {
    public private(set) var favourites: Set<String> = []
    public private(set) var captions: [String: String] = [:]

    public static let maximumCaptionLength = 80

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favourites = (try? c.decodeIfPresent(Set<String>.self, forKey: .favourites)) ?? []
        captions = ((try? c.decodeIfPresent([String: String].self, forKey: .captions)) ?? [:])
            .mapValues { String($0.prefix(Self.maximumCaptionLength)) }
    }

    public func isFavourite(_ file: String) -> Bool { favourites.contains(file) }

    @discardableResult
    public mutating func toggleFavourite(_ file: String) -> Bool {
        if favourites.remove(file) != nil { return false }
        favourites.insert(file)
        return true
    }

    public func caption(for file: String) -> String? { captions[file] }

    /// A caption; empty clears it.
    public mutating func setCaption(_ text: String, for file: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumCaptionLength))
        captions[file] = trimmed.isEmpty ? nil : trimmed
    }

    /// Notes about files that are gone.
    public mutating func keepOnly(_ files: Set<String>) {
        favourites.formIntersection(files)
        captions = captions.filter { files.contains($0.key) }
    }

    /// A copy made by editing keeps the caption and the heart.
    public mutating func copy(_ file: String, to newFile: String) {
        if favourites.contains(file) { favourites.insert(newFile) }
        if let caption = captions[file] { captions[newFile] = caption }
    }
}

// MARK: - Showing the album

public enum AlbumShow: String, CaseIterable, Sendable, Identifiable {
    case all, pictures, clips, favourites

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return L("All")
        case .pictures: return L("Pictures")
        case .clips: return L("Clips")
        case .favourites: return L("Favourites")
        }
    }
}

public enum AlbumGrouping: String, CaseIterable, Sendable, Identifiable {
    case day, game, none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .day: return L("By day")
        case .game: return L("By game")
        case .none: return L("All together")
        }
    }
}

public enum AlbumSection: Hashable, Sendable {
    case today, yesterday, day(Date), game(String), all
}

public enum AlbumLayout {

    /// The entries that pass what is shown, and one game if chosen.
    public static func filter(_ entries: [AlbumEntry], show: AlbumShow, notes: AlbumNotes, game: String? = nil,
                              search: String = "") -> [AlbumEntry] {
        entries.filter { entry in
            let kind: Bool
            switch show {
            case .all: kind = true
            case .pictures: kind = !entry.isClip
            case .clips: kind = entry.isClip
            case .favourites: kind = notes.isFavourite(entry.id)
            }
            let caption = notes.caption(for: entry.id) ?? ""
            return kind && (game.map { entry.game == $0 } ?? true)
                && SearchText.matches(search, in: [entry.game, caption])
        }
    }

    /// Entries in sections, newest (or oldest) first within and between them.
    public static func sections(_ entries: [AlbumEntry], grouping: AlbumGrouping, newestFirst: Bool = true,
                                now: Date = Date(), calendar: Calendar = .current) -> [(section: AlbumSection, entries: [AlbumEntry])] {
        let ordered = entries.sorted { newestFirst ? $0.date > $1.date : $0.date < $1.date }
        switch grouping {
        case .none:
            return ordered.isEmpty ? [] : [(.all, ordered)]
        case .game:
            var order: [String] = []
            var groups: [String: [AlbumEntry]] = [:]
            for entry in ordered {
                if groups[entry.game] == nil { order.append(entry.game) }
                groups[entry.game, default: []].append(entry)
            }
            return order.map { (.game($0), groups[$0] ?? []) }
        case .day:
            var order: [Date] = []
            var groups: [Date: [AlbumEntry]] = [:]
            for entry in ordered {
                let day = calendar.startOfDay(for: entry.date)
                if groups[day] == nil { order.append(day) }
                groups[day, default: []].append(entry)
            }
            let today = calendar.startOfDay(for: now)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            return order.map { day in
                let section: AlbumSection = day == today ? .today : day == yesterday ? .yesterday : .day(day)
                return (section, groups[day] ?? [])
            }
        }
    }

    /// Every game with pictures, most pictures first.
    public static func games(in entries: [AlbumEntry]) -> [(game: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.game, default: 0] += 1 }
        return counts.map { (game: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.game < $1.game }
    }

    /// "12.4 MB".
    public static func sizeText(_ bytes: Int) -> String {
        let value = Double(Swift.max(0, bytes))
        if value < 1_000 { return L("{} bytes", Int(value)) }
        if value < 1_000_000 { return L("{} KB", Int((value / 1_000).rounded())) }
        if value < 1_000_000_000 { return L("{} MB", String(format: "%.1f", value / 1_000_000)) }
        return L("{} GB", String(format: "%.2f", value / 1_000_000_000))
    }
}

// MARK: - Photo mode

/// The shape a picture is cut to.
public enum PhotoCrop: String, Codable, CaseIterable, Sendable, Identifiable {
    case original, square, fourThree, wide, tall

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return L("As it is")
        case .square: return L("Square")
        case .fourThree: return "4:3"
        case .wide: return "16:9"
        case .tall: return "3:4"
        }
    }

    /// Width over height, or nil to keep the picture's own.
    public var aspect: Double? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .wide: return 16.0 / 9
        case .tall: return 3.0 / 4
        }
    }

    /// The largest centred rectangle of this shape inside a picture.
    public func rect(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        guard let aspect, width > 0, height > 0 else { return (0, 0, width, height) }
        if width / height > aspect {
            let w = (height * aspect).rounded()
            return (((width - w) / 2).rounded(), 0, w, height)
        }
        let h = (width / aspect).rounded()
        return (0, ((height - h) / 2).rounded(), width, h)
    }
}

/// A border drawn round a picture as it is saved.
public enum PhotoFrame: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, white, instant, film, gold, candy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return L("No frame")
        case .white: return L("White")
        case .instant: return L("Instant photo")
        case .film: return L("Film")
        case .gold: return L("Gold")
        case .candy: return L("Candy")
        }
    }

    /// Border widths as a share of the picture's shorter side: sides, top,
    /// bottom (an instant photo's bottom is deep, for writing on).
    public var borders: (side: Double, top: Double, bottom: Double) {
        switch self {
        case .none: return (0, 0, 0)
        case .white, .gold, .candy: return (0.04, 0.04, 0.04)
        case .instant: return (0.05, 0.05, 0.2)
        case .film: return (0.02, 0.09, 0.09)
        }
    }

    public var colour: ColorRGBA {
        switch self {
        case .none, .white, .instant: return ColorRGBA(r: 0.98, g: 0.98, b: 0.97)
        case .film: return ColorRGBA(r: 0.08, g: 0.08, b: 0.09)
        case .gold: return ColorRGBA(r: 0.85, g: 0.66, b: 0.22)
        case .candy: return ColorRGBA(r: 0.98, g: 0.66, b: 0.83)
        }
    }

    /// The finished picture's size for a picture of this size.
    public func framedSize(width: Double, height: Double) -> (width: Double, height: Double) {
        let unit = Swift.min(width, height)
        let b = borders
        return ((width + 2 * b.side * unit).rounded(), (height + (b.top + b.bottom) * unit).rounded())
    }
}

/// Photo mode's choices, kept between visits.
public struct PhotoModeOptions: Codable, Hashable, Sendable {
    /// Seconds before the picture is taken: 0, 3 or 10.
    public var timer = 0
    public static let timerChoices = [0, 3, 10]
    /// Three pictures in a row.
    public var burst = false
    /// Lines in thirds while framing.
    public var grid = false
    public var crop: PhotoCrop = .original
    public var frame: PhotoFrame = .none
    /// The game's name and the date written in a corner.
    public var stamp = false
    /// Degrees added to the camera's view while framing: a zoom lens.
    public var zoom: Float = 0
    public static let zoomRange: ClosedRange<Float> = -25...25

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PhotoModeOptions()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        timer = read(.timer, d.timer)
        if !Self.timerChoices.contains(timer) { timer = 0 }
        burst = read(.burst, d.burst)
        grid = read(.grid, d.grid)
        crop = read(.crop, d.crop)
        frame = read(.frame, d.frame)
        stamp = read(.stamp, d.stamp)
        zoom = read(.zoom, d.zoom)
        zoom = zoom.isFinite ? Swift.min(Swift.max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) : 0
    }

    /// How many pictures one press takes.
    public var shots: Int { burst ? 3 : 1 }

    /// What the stamp says.
    public static func stampText(game: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(game) · \(formatter.string(from: date))"
    }
}
