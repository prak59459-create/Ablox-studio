import Foundation

/// The sound effects library: thousands of short recordings a game can play
/// by name — `sound("retro-game-coin-08")` in a script, or a rule's "Play a
/// sound".
///
/// ## Where the sounds come from
///
/// Every file is from SFXMint (https://sfxmint.com), whose whole library is
/// CC0: free to use, change and share, with no credit owed. A copy lives in
/// the game list repository under `sounds/`, beside the games, so the app
/// reads it from the same place and the same branch as the game list, and the
/// app's own update stays small. `sounds/index.json` lists every sound with
/// its size and SHA-256, so a file is kept only when it is exactly the one
/// listed.
///
/// ## Names
///
/// A library sound is named by its id: lowercase letters and digits in
/// words joined by hyphens (`retro-game-coin-08`). The built-in cues
/// (`coin`, `jump`, …) are single words, so the two can never be confused.
public struct SoundLibrary: Sendable {

    /// A group the library is browsed by: "UI", "Retro game", "Animals"…
    public struct Category: Sendable, Identifiable, Hashable {
        public let id: String
        public let english: String
        public let japanese: String
        /// More words that find it.
        public let keywords: String

        public init(id: String, english: String, japanese: String, keywords: String = "") {
            self.id = id
            self.english = english
            self.japanese = japanese
            self.keywords = keywords
        }

        /// The name in the language the app is showing.
        public var title: String {
            Localization.language == .japanese ? japanese : english
        }
    }

    /// Takes of one kind of sound: "Retro Coin" 01 to 44.
    public struct Family: Sendable, Identifiable, Hashable {
        public let id: String
        public let english: String
        /// Its name in Japanese, when the words in it could be put so.
        public let japanese: String
        /// More words to find it by: readings in hiragana, other words.
        public let keywords: String
        public let category: String
        public let sounds: [Sound]

        public init(id: String, english: String, japanese: String, keywords: String = "", category: String, sounds: [Sound]) {
            self.id = id
            self.english = english
            self.japanese = japanese
            self.keywords = keywords
            self.category = category
            self.sounds = sounds
        }

        public var title: String {
            Localization.language == .japanese && !japanese.isEmpty ? japanese : english
        }

        public var bytes: Int { sounds.reduce(0) { $0 + $1.bytes } }
    }

    public struct Sound: Sendable, Identifiable, Hashable {
        public let id: String
        /// "Sparkling 8-Bit Coin Pickup 36", in English.
        public let title: String
        public let category: String
        /// How long the file plays, in milliseconds.
        public let milliseconds: Int
        public let bytes: Int
        /// Lowercase hex.
        public let sha256: String

        public init(id: String, title: String = "", category: String, milliseconds: Int, bytes: Int, sha256: String) {
            self.id = id
            self.title = title
            self.category = category
            self.milliseconds = milliseconds
            self.bytes = bytes
            self.sha256 = sha256
        }

        /// Where the file is in the repository.
        public var path: String { "sounds/\(category)/\(id).mp3" }

        /// The take number at the end of the id ("08"), or the whole id.
        public var shortName: String {
            guard let dash = id.lastIndex(of: "-") else { return id }
            let tail = id[id.index(after: dash)...]
            return tail.allSatisfy(\.isNumber) ? String(tail) : id
        }

        /// "0.8 s".
        public var lengthText: String {
            String(format: "%.1f s", Double(milliseconds) / 1000)
        }
    }

    public let categories: [Category]
    public let families: [Family]
    /// Where the files came from, as the index says it.
    public let source: String
    public let license: String
    public let updated: String?

    private let byID: [String: Sound]
    private let familyOf: [String: Int]

    public init(categories: [Category], families: [Family], source: String = "", license: String = "", updated: String? = nil) {
        self.categories = categories
        self.families = families
        self.source = source
        self.license = license
        self.updated = updated
        var byID: [String: Sound] = [:]
        var familyOf: [String: Int] = [:]
        for (index, family) in families.enumerated() {
            for sound in family.sounds where byID[sound.id] == nil {
                byID[sound.id] = sound
                familyOf[sound.id] = index
            }
        }
        self.byID = byID
        self.familyOf = familyOf
    }

    public var soundCount: Int { byID.count }

    public var totalBytes: Int { byID.values.reduce(0) { $0 + $1.bytes } }

    public func sound(_ id: String) -> Sound? { byID[id] }

    public func family(of id: String) -> Family? { familyOf[id].map { families[$0] } }

    public func category(_ id: String) -> Category? { categories.first { $0.id == id } }

    public func families(in category: String) -> [Family] {
        families.filter { $0.category == category }
    }

    // MARK: Names

    /// The longest id the library accepts.
    public static let maximumIDLength = 96

    /// Whether `name` is shaped like a library id: words of lowercase
    /// letters and digits joined by single hyphens, at least two words.
    /// Says nothing about whether the library has it.
    public static func isLibraryID(_ name: String) -> Bool {
        guard name.count <= maximumIDLength, name.contains("-"),
              !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return name.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }

    /// Every library id a world's scripts and rules name, in the order
    /// they first appear: what to fetch before the game starts, so the
    /// first coin does not wait for the network. Names the library does not
    /// have are the caller's to drop.
    public static func ids(in world: WorldDocument) -> [String] {
        var names: [String] = []
        for rule in world.rules {
            for action in rule.actions {
                if case let .playSound(name) = action { names.append(name) }
            }
        }
        return ids(inScripts: world.scripts.filter(\.isEnabled).map(\.source), soundNames: names)
    }

    /// The same for script text alone: every quoted string shaped like an
    /// id. Comments (`--` to the end of the line) are skipped, so an
    /// apostrophe in one cannot start a string.
    public static func ids(inScripts sources: [String], soundNames: [String] = []) -> [String] {
        let limit = 200
        var seen = Set<String>()
        var found: [String] = []
        func add(_ name: String) {
            if found.count < limit, isLibraryID(name), seen.insert(name).inserted { found.append(name) }
        }
        for name in soundNames { add(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        for source in sources {
            var inString = false
            var inComment = false
            var current = ""
            var previous: Character = " "
            for character in source {
                if character.isNewline {
                    inString = false
                    inComment = false
                    current = ""
                } else if inComment {
                    // Skipped to the end of the line.
                } else if inString {
                    if Self.quotes.contains(character) {
                        inString = false
                        add(current)
                        current = ""
                    } else if current.count <= maximumIDLength {
                        current.append(character)
                    }
                } else if Self.quotes.contains(character) {
                    inString = true
                } else if character == "-", previous == "-" {
                    inComment = true
                }
                previous = character
            }
            if found.count >= limit { break }
        }
        return found
    }

    private static let quotes: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "＂"]

    // MARK: Search

    /// Families whose names, Japanese words, category or ids contain every
    /// word of `query`, best first. An empty query lists them all.
    public func search(_ query: String, category: String? = nil) -> [Family] {
        let pool = category.map { families(in: $0) } ?? families
        let words = Self.words(query)
        guard !words.isEmpty else { return pool }
        var scored: [(score: Int, index: Int, family: Family)] = []
        for (index, family) in pool.enumerated() {
            let english = family.english.lowercased()
            let japanese = family.japanese.lowercased()
            let categoryNames = self.category(family.category).map { "\($0.english) \($0.japanese) \($0.keywords)".lowercased() } ?? ""
            let haystack = "\(english) \(japanese) \(family.keywords.lowercased()) \(family.id) \(family.category) \(categoryNames)"
            var score = 0
            var all = true
            for word in words {
                if english.hasPrefix(word) || family.id.hasPrefix(word) || japanese.hasPrefix(word) {
                    score += 3
                } else if english.contains(word) || japanese.contains(word) {
                    score += 2
                } else if haystack.contains(word) {
                    score += 1
                } else if family.sounds.contains(where: { $0.id == word }) {
                    score += 4
                } else if family.sounds.contains(where: { $0.title.lowercased().contains(word) }) {
                    score += 1
                } else {
                    all = false
                    break
                }
            }
            if all { scored.append((score, index, family)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.map(\.family)
    }

    static func words(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "　" || $0 == "," || $0 == "、" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: Reading the index

    public enum Limits {
        public static let maximumIndexBytes = 8 * 1024 * 1024
        public static let maximumSoundBytes = 4 * 1024 * 1024
        public static let maximumSounds = 50_000
        public static let indexPath = "sounds/index.json"
    }

    /// Reads `sounds/index.json`. Sounds whose id, category, size or hash
    /// could not be what they claim are left out rather than failing the
    /// whole library.
    public static func decode(indexData data: Data) throws -> SoundLibrary {
        guard data.count <= Limits.maximumIndexBytes else { throw SoundLibraryError.tooLarge }
        let index: IndexFile
        do {
            index = try JSONDecoder().decode(IndexFile.self, from: data)
        } catch {
            throw SoundLibraryError.unreadable
        }
        guard index.version == 1 else { throw SoundLibraryError.newerVersion }
        let categories = index.categories.compactMap { entry -> Category? in
            guard isSafeName(entry.id) else { return nil }
            return Category(id: entry.id, english: String(entry.en.prefix(60)), japanese: String((entry.ja ?? entry.en).prefix(60)),
                            keywords: String((entry.k ?? "").prefix(200)))
        }
        var count = 0
        var families: [Family] = []
        for entry in index.families {
            guard isSafeName(entry.id), isSafeName(entry.c) else { continue }
            let sounds = entry.s.compactMap { row -> Sound? in
                guard count < Limits.maximumSounds, isLibraryID(row.id), row.bytes > 0, row.bytes <= Limits.maximumSoundBytes,
                      row.sha256.count == 64, row.sha256.allSatisfy(\.isHexDigit) else { return nil }
                count += 1
                return Sound(id: row.id, title: String(row.title.prefix(80)), category: entry.c, milliseconds: max(0, row.milliseconds),
                             bytes: row.bytes, sha256: row.sha256.lowercased())
            }
            guard !sounds.isEmpty else { continue }
            families.append(Family(id: entry.id, english: String(entry.en.prefix(80)), japanese: String((entry.ja ?? "").prefix(80)),
                                   keywords: String((entry.k ?? "").prefix(300)), category: entry.c, sounds: sounds))
        }
        return SoundLibrary(categories: categories, families: families, source: index.source ?? "",
                            license: index.license ?? "", updated: index.updated)
    }

    /// A category or family id: the same shape as a sound id, or one word.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && (isLibraryID(name) || (name.count <= 40 && name.unicodeScalars.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }))
    }

    private struct IndexFile: Decodable {
        let version: Int
        let license: String?
        let source: String?
        let updated: String?
        let categories: [CategoryEntry]
        let families: [FamilyEntry]
    }

    private struct CategoryEntry: Decodable {
        let id: String
        let en: String
        let ja: String?
        let k: String?
    }

    private struct FamilyEntry: Decodable {
        let id: String
        let en: String
        let ja: String?
        let k: String?
        let c: String
        let s: [SoundRow]
    }

    /// `["retro-game-coin-08", 1031, 16927, "ab12…", "Short 8-Bit Coin
    /// Pickup 08"]`: id, milliseconds, bytes, SHA-256 and, if there is one,
    /// a title. Rows rather than objects, since there are thousands.
    private struct SoundRow: Decodable {
        let id: String
        let milliseconds: Int
        let bytes: Int
        let sha256: String
        let title: String

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            id = try row.decode(String.self)
            milliseconds = try row.decode(Int.self)
            bytes = try row.decode(Int.self)
            sha256 = try row.decode(String.self)
            title = row.isAtEnd ? "" : ((try? row.decode(String.self)) ?? "")
        }
    }
}

public enum SoundLibraryError: Error, Equatable, Sendable {
    case tooLarge
    case unreadable
    case newerVersion

    public var message: String {
        switch self {
        case .tooLarge: return L("The sound list is too big to be the real one.")
        case .unreadable: return L("The sound list could not be read.")
        case .newerVersion: return L("The sound list needs a newer Ablox. Update the app.")
        }
    }
}
