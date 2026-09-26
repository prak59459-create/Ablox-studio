import Foundation

// MARK: - SaveValue

/// One value a game has saved: what `p.save("coins", 120)` stores.
///
/// Only plain data — numbers, text, true/false, lists and maps of those.
/// Functions, players and blocks mean nothing outside the round that made
/// them, so they are refused rather than saved as something broken.
public enum SaveValue: Codable, Hashable, Sendable {
    /// An empty slot in a list: `[3, nil, 5]` keeps its shape. (A key set to
    /// nil in a map is simply not saved.)
    case null
    case number(Double)
    case string(String)
    case bool(Bool)
    case list([SaveValue])
    case map([String: SaveValue])

    /// Encoded as the plain JSON value, so a save file reads like the data
    /// the game wrote: `"coins": 120`, not `{"number": 120}`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        // Bool first: JSONDecoder will not read `true` as a number, but some
        // decoders read 1 as true.
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SaveValue].self) {
            self = .list(value)
        } else if let value = try? container.decode([String: SaveValue].self) {
            self = .map(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a saved value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .list(value): try container.encode(value)
        case let .map(value): try container.encode(value)
        }
    }

    /// How many values this is, counting everything inside a list or map.
    var nodeCount: Int {
        switch self {
        case .null, .number, .string, .bool: return 1
        case let .list(items): return 1 + items.reduce(0) { $0 + $1.nodeCount }
        case let .map(entries): return 1 + entries.values.reduce(0) { $0 + $1.nodeCount }
        }
    }

    var depth: Int {
        switch self {
        case .null, .number, .string, .bool: return 1
        case let .list(items): return 1 + (items.map(\.depth).max() ?? 0)
        case let .map(entries): return 1 + (entries.values.map(\.depth).max() ?? 0)
        }
    }
}

// MARK: - SaveData

/// Everything one player has saved in one game.
///
/// It lives on the player's own iPad, is sent to whoever hosts when they
/// join, and comes back whenever the game saves. The host can therefore
/// never trust it more than anything else a guest says about themselves:
/// it is bounded here, on both the way in and the way out, so a hand-edited
/// file or a misbehaving peer can only ever produce a small, well-formed map.
public struct SaveData: Codable, Hashable, Sendable {

    public enum Limits {
        public static let maximumKeys = 200
        public static let maximumKeyLength = 64
        public static let maximumStringLength = 2_000
        public static let maximumDepth = 6
        /// Values in total, counting inside lists and maps.
        public static let maximumNodes = 5_000
        /// The whole thing as JSON. Generous for a game's progress, small
        /// enough to send on every save without anyone noticing.
        public static let maximumEncodedBytes = 64 * 1024
    }

    public private(set) var values: [String: SaveValue]

    public init(_ values: [String: SaveValue] = [:]) {
        self.values = [:]
        for key in values.keys.sorted() {
            if let value = values[key] { _ = set(key, value) }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Through `init(_:)`, so a file edited by hand is held to the same
        // limits as values a script sets.
        self.init(try container.decode([String: SaveValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public var isEmpty: Bool { values.isEmpty }
    public var count: Int { values.count }

    public subscript(key: String) -> SaveValue? { values[key] }

    /// Stores a value, or removes the key when `value` is nil.
    ///
    /// Returns false, changing nothing, when the value would break a limit —
    /// the caller tells the script why.
    @discardableResult
    public mutating func set(_ key: String, _ value: SaveValue?) -> Bool {
        guard let value else {
            values[key] = nil
            return true
        }
        guard value != .null else {
            values[key] = nil
            return true
        }
        guard Self.isValidKey(key), let clean = Self.cleaned(value) else { return false }
        if values[key] == nil, values.count >= Limits.maximumKeys { return false }
        var candidate = values
        candidate[key] = clean
        let nodes = candidate.values.reduce(0) { $0 + $1.nodeCount }
        guard nodes <= Limits.maximumNodes, Self.encodedSize(of: candidate) <= Limits.maximumEncodedBytes else { return false }
        values = candidate
        return true
    }

    public var encodedSize: Int { Self.encodedSize(of: values) }

    // MARK: Checks

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= Limits.maximumKeyLength
    }

    /// The value with over-long text cut and anything unsavable refused.
    static func cleaned(_ value: SaveValue, depth: Int = 1) -> SaveValue? {
        guard depth <= Limits.maximumDepth else { return nil }
        switch value {
        case let .number(number):
            return number.isFinite ? value : nil
        case let .string(text):
            return .string(String(text.prefix(Limits.maximumStringLength)))
        case .bool, .null:
            return value
        case let .list(items):
            var cleaned: [SaveValue] = []
            for item in items {
                guard let item = self.cleaned(item, depth: depth + 1) else { return nil }
                cleaned.append(item)
            }
            return .list(cleaned)
        case let .map(entries):
            var cleaned: [String: SaveValue] = [:]
            for (key, item) in entries where item != .null {
                guard isValidKey(key), let item = self.cleaned(item, depth: depth + 1) else { return nil }
                cleaned[key] = item
            }
            return .map(cleaned)
        }
    }

    static func encodedSize(of values: [String: SaveValue]) -> Int {
        (try? JSONEncoder().encode(values).count) ?? Int.max
    }
}

// MARK: - GameSaveStore

/// Saved game data on this iPad: one small JSON file per world.
///
/// Keyed by the world's id, which a catalogue game keeps no matter who hosts
/// it — progress made in a friend's room is there next time you host the same
/// game yourself. Each write keeps the previous file as a backup, and a file
/// that will not read falls back to it, so a crash mid-write or a bad disk
/// sector costs at most one save rather than all of it.
public final class GameSaveStore {

    public struct Summary: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let worldName: String
        public let savedAt: Date
        public let keyCount: Int
        public let byteCount: Int
    }

    /// What is on disk for one world.
    public struct Record: Codable, Hashable, Sendable {
        public var version = 1
        public var worldID: UUID
        public var worldName: String
        public var savedAt: Date
        public var data: SaveData

        public init(worldID: UUID, worldName: String, savedAt: Date, data: SaveData) {
            self.worldID = worldID
            self.worldName = worldName
            self.savedAt = savedAt
            self.data = data
        }
    }

    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Application Support/Saves. Not Caches: the system may empty Caches
    /// whenever it likes, and this is a child's progress.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Saves", isDirectory: true)
    }

    // MARK: Reading

    public func record(for worldID: UUID) -> Record? {
        for url in [fileURL(for: worldID), backupURL(for: worldID)] {
            if let data = try? Data(contentsOf: url), let record = try? Self.decoder.decode(Record.self, from: data) {
                return record
            }
        }
        return nil
    }

    public func load(worldID: UUID) -> SaveData? {
        record(for: worldID)?.data
    }

    public func summaries() -> [Summary] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url -> Summary? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let record = record(for: id) else { return nil }
                return Summary(id: id, worldName: record.worldName, savedAt: record.savedAt,
                               keyCount: record.data.count, byteCount: record.data.encodedSize)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public var allRecords: [Record] {
        summaries().compactMap { record(for: $0.id) }
    }

    // MARK: Writing

    public func save(_ data: SaveData, worldID: UUID, worldName: String, at date: Date = Date()) throws {
        let record = Record(worldID: worldID, worldName: worldName, savedAt: date, data: data)
        let encoded = try Self.encoder.encode(record)
        let url = fileURL(for: worldID)
        // The last good file becomes the backup before the new one lands.
        if fileManager.fileExists(atPath: url.path) {
            let backup = backupURL(for: worldID)
            try? fileManager.removeItem(at: backup)
            try? fileManager.copyItem(at: url, to: backup)
        }
        try encoded.write(to: url, options: [.atomic])
    }

    /// Puts back records from a backup file, keeping whichever copy of each
    /// world is newer.
    @discardableResult
    public func merge(_ records: [Record]) -> Int {
        var restored = 0
        for incoming in records {
            if let existing = record(for: incoming.worldID), existing.savedAt >= incoming.savedAt { continue }
            if (try? save(incoming.data, worldID: incoming.worldID, worldName: incoming.worldName, at: incoming.savedAt)) != nil {
                restored += 1
            }
        }
        return restored
    }

    public func delete(worldID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: worldID))
        try? fileManager.removeItem(at: backupURL(for: worldID))
    }

    public func deleteAll() {
        for summary in summaries() { delete(worldID: summary.id) }
    }

    // MARK: Files

    static let fileExtension = "save"

    private func fileURL(for worldID: UUID) -> URL {
        directory.appendingPathComponent(worldID.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private func backupURL(for worldID: UUID) -> URL {
        directory.appendingPathComponent(worldID.uuidString).appendingPathExtension("bak")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
