import Foundation

/// The public list of worlds people have published, served from a GitHub
/// repository rather than a server.
///
/// ## Why a repository
///
/// Ablox has no backend and is not getting one. A public repo gives the three
/// things a catalogue actually needs — a place to put files, a way for other
/// people to add to it, and a URL — for nothing, and it keeps the property
/// that matters: the app only ever *reads*. Nobody's iPad has an account,
/// there is no login, and publishing is a pull request, which is also a review
/// step that a plain upload form would not have.
///
/// The repository layout the app expects:
///
/// ```
/// index.json
/// games/
///   sky-temple/
///     world.ablox     the WorldDocument, as saved by Studio
///     cover.png       the picture shown in the list
/// ```
///
/// ## Everything here is untrusted
///
/// Anything fetched from the internet is written by someone else. A listing
/// can name a path, and that path is joined to a base URL *and* to a folder in
/// the app's cache — so `../../` in the wrong field is a file written outside
/// the sandbox directory, and a 400 MB world is an iPad that runs out of
/// memory opening a menu.
///
/// So this file is mostly limits and refusals, and they are enforced here, in
/// the portable core, where they can be tested — not in the networking layer
/// where nothing can be.
public struct GameCatalogue: Codable, Equatable, Sendable {

    /// Bumped when the shape of `index.json` changes incompatibly. An index
    /// from the future is refused with a readable message rather than decoded
    /// into something half-understood.
    public static let currentVersion = 1

    public var catalogueVersion: Int
    public var updatedAt: Date
    public var games: [GameListing]

    public init(
        catalogueVersion: Int = GameCatalogue.currentVersion,
        updatedAt: Date = Date(),
        games: [GameListing] = []
    ) {
        self.catalogueVersion = catalogueVersion
        self.updatedAt = updatedAt
        self.games = games
    }
}

/// One published world.
public struct GameListing: Codable, Equatable, Identifiable, Sendable {

    /// Folder-safe identifier, also the cache key. See `Limits.isValidID`.
    public var id: String
    public var title: String
    public var author: String
    public var summary: String
    /// Repository-relative path to the world file.
    public var world: String
    /// Repository-relative path to the cover image. Optional: a world without
    /// a picture is listed with a generated placeholder rather than hidden.
    public var cover: String?
    public var tags: [String]
    /// What the publisher says is in it. Shown before downloading, and checked
    /// against the real world afterwards — see `GameListing.mismatch(with:)`.
    public var blockCount: Int
    public var maxPlayers: Int
    /// The world file's own schema version, so an index can be read by an app
    /// too old to open some of what it lists.
    public var schemaVersion: Int
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        author: String = "",
        summary: String = "",
        world: String,
        cover: String? = nil,
        tags: [String] = [],
        blockCount: Int = 0,
        maxPlayers: Int = 4,
        schemaVersion: Int = WorldDocument.currentSchemaVersion,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.world = world
        self.cover = cover
        self.tags = tags
        self.blockCount = blockCount
        self.maxPlayers = maxPlayers
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }

    /// Whether this app can open the world at all.
    public var isSupported: Bool {
        schemaVersion <= WorldDocument.currentSchemaVersion
    }

    public var displayAuthor: String {
        author.isEmpty ? L("Unknown") : author
    }
}

// MARK: - Limits

public extension GameCatalogue {

    /// The bounds everything downloaded is held to.
    ///
    /// Numbers rather than "reasonable": a limit nobody wrote down is a limit
    /// nobody enforces. Each is generous for an honest world and small enough
    /// that a dishonest one cannot take the app down.
    enum Limits {
        /// `index.json`. A thousand listings is about 400 KB of JSON.
        public static let maximumIndexBytes = 2 * 1024 * 1024
        public static let maximumGames = 1_000

        /// A world file. Studio's own biggest test world is under 300 KB; this
        /// leaves room for a very large one while keeping decode time bounded.
        public static let maximumWorldBytes = 8 * 1024 * 1024
        /// Matches what the renderer can hold at a usable frame rate.
        public static let maximumBlocks = 5_000

        public static let maximumCoverBytes = 4 * 1024 * 1024

        public static let maximumIDLength = 64
        public static let maximumTitleLength = 60
        public static let maximumAuthorLength = 40
        public static let maximumSummaryLength = 280
        public static let maximumTags = 8
        public static let maximumTagLength = 24
        public static let maximumPathLength = 200

        /// Lowercase letters, digits and single hyphens.
        ///
        /// Deliberately narrower than "a valid filename". The id becomes a
        /// folder in the app's cache directory and a path component in a URL,
        /// so anything that could mean "the parent directory", "a different
        /// host", or "the same name in a different case" is refused rather
        /// than escaped. Two listings whose ids differ only in case would
        /// collide on a case-insensitive filesystem, which is what an iPad
        /// has.
        public static func isValidID(_ id: String) -> Bool {
            guard !id.isEmpty, id.count <= maximumIDLength else { return false }
            guard id.first != "-", id.last != "-" else { return false }
            guard !id.contains("--") else { return false }
            return id.allSatisfy { character in
                character.isASCII && (character.isLowercase || character.isNumber || character == "-")
            }
        }

        /// A path inside the repository, and nowhere else.
        ///
        /// The rules are about what the path could *become* once it is joined
        /// to a base URL or to a cache directory, not about what it looks
        /// like: a leading slash makes it absolute, `..` climbs out, a scheme
        /// makes it another server entirely, and a backslash or a null byte
        /// is a different string to the filesystem than it is to this check.
        public static func isValidRepositoryPath(_ path: String, extensions: [String]) -> Bool {
            guard !path.isEmpty, path.count <= maximumPathLength else { return false }
            guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
            guard !path.contains("\\"), !path.contains("\0") else { return false }
            guard !path.contains("//") else { return false }
            // Any scheme at all, not just http — `file:` and `data:` are the
            // interesting ones to keep out.
            guard !path.contains(":") else { return false }

            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty else { return false }
            for component in components {
                guard !component.isEmpty else { return false }
                guard component != "..", component != "." else { return false }
                // A leading dot hides the file on disk and is never something
                // an honest listing needs.
                guard !component.hasPrefix(".") else { return false }
            }

            guard let name = components.last else { return false }
            return extensions.contains { name.lowercased().hasSuffix(".\($0)") }
        }

        public static let worldExtensions = ["ablox", "json"]
        public static let coverExtensions = ["png", "jpg", "jpeg"]
    }
}

// MARK: - Validation

/// Why a listing or an index was refused.
///
/// A case per reason rather than a string, so the app can decide what to do
/// with each — a listing this version cannot open is worth showing greyed out,
/// a listing with a traversal attempt in it is worth dropping silently.
public enum CatalogueRejection: Equatable, Sendable {
    case wrongVersion(found: Int, supported: Int)
    case tooLarge(bytes: Int, limit: Int)
    case tooManyGames(found: Int, limit: Int)
    case malformed(String)

    case invalidID(String)
    case invalidPath(field: String, value: String)
    case fieldTooLong(field: String, limit: Int)
    case duplicateID(String)
    case unsupportedSchema(id: String, schemaVersion: Int)

    public var message: String {
        switch self {
        case let .wrongVersion(found, supported):
            return L("This game list needs a newer version of Ablox (list {}, this app reads {}).", found, supported)
        case .tooLarge:
            return L("That download was too big and was refused.")
        case .tooManyGames:
            return L("That game list is too long and was refused.")
        case let .malformed(detail):
            return detail.isEmpty ? L("That game list could not be read.") : detail
        case .invalidID, .invalidPath, .fieldTooLong, .duplicateID:
            return L("Part of that game list was malformed and was skipped.")
        case .unsupportedSchema:
            return L("That world was made with a newer version of Ablox Studio.")
        }
    }
}

public extension GameCatalogue {

    /// What survived validation, and what did not.
    ///
    /// One bad listing does not throw away the catalogue. A repository anyone
    /// can open a pull request against will eventually contain a typo, and
    /// hiding nine hundred working games because of it would be the wrong
    /// trade — so bad entries are dropped and reported, and the rest are kept.
    struct ValidationResult: Equatable, Sendable {
        public var accepted: [GameListing]
        public var rejected: [(id: String, reason: CatalogueRejection)]

        public static func == (a: ValidationResult, b: ValidationResult) -> Bool {
            a.accepted == b.accepted
                && a.rejected.count == b.rejected.count
                && zip(a.rejected, b.rejected).allSatisfy { $0.id == $1.id && $0.reason == $1.reason }
        }
    }

    /// Decodes an `index.json`, refusing the whole thing only for problems
    /// that make it meaningless.
    static func decode(indexData data: Data) throws -> GameCatalogue {
        guard data.count <= Limits.maximumIndexBytes else {
            throw CatalogueError(.tooLarge(bytes: data.count, limit: Limits.maximumIndexBytes))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let catalogue: GameCatalogue
        do {
            catalogue = try decoder.decode(GameCatalogue.self, from: data)
        } catch {
            throw CatalogueError(.malformed(error.localizedDescription))
        }

        guard catalogue.catalogueVersion <= currentVersion else {
            throw CatalogueError(.wrongVersion(found: catalogue.catalogueVersion, supported: currentVersion))
        }
        guard catalogue.games.count <= Limits.maximumGames else {
            throw CatalogueError(.tooManyGames(found: catalogue.games.count, limit: Limits.maximumGames))
        }
        return catalogue
    }

    /// Filters the listings down to the ones that are safe and openable.
    func validated() -> ValidationResult {
        var accepted: [GameListing] = []
        var rejected: [(id: String, reason: CatalogueRejection)] = []
        var seen: Set<String> = []

        for listing in games {
            if let reason = listing.rejection(alreadySeen: seen) {
                rejected.append((listing.id, reason))
                continue
            }
            seen.insert(listing.id)
            accepted.append(listing)
        }

        return ValidationResult(accepted: accepted, rejected: rejected)
    }
}

/// Thrown by `GameCatalogue.decode(indexData:)`.
public struct CatalogueError: Error, Equatable, Sendable {
    public let rejection: CatalogueRejection
    public init(_ rejection: CatalogueRejection) { self.rejection = rejection }
    public var message: String { rejection.message }
}

public extension GameListing {

    /// Turns a title into an id the catalogue will accept.
    ///
    /// The rules in `Limits.isValidID` are narrow — lowercase ASCII, single
    /// hyphens — and most titles do not survive them. A Japanese title
    /// survives none of it, so there is a fallback: a stable hash of the
    /// original, which is still unique per title and still a valid id.
    ///
    /// Stable rather than random, so publishing the same world twice produces
    /// the same id and the second attempt updates the first rather than
    /// appearing beside it.
    static func suggestedID(for title: String) -> String {
        var slug = ""
        var lastWasHyphen = true      // so a leading hyphen is never emitted

        for character in title.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }

        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(GameCatalogue.Limits.maximumIDLength))
        while slug.hasSuffix("-") { slug.removeLast() }

        guard GameCatalogue.Limits.isValidID(slug) else {
            // FNV-1a over the original, so a title with no ASCII in it still
            // gets an id, and always the same one.
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in Array(title.utf8) {
                hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
            }
            return "world-" + String(hash % 0xffff_ffff, radix: 36)
        }
        return slug
    }

    /// The listing Studio proposes for a world, ready to be edited and
    /// pasted into the catalogue.
    static func draft(for world: WorldDocument, author: String) -> GameListing {
        let id = suggestedID(for: world.name)
        return GameListing(
            id: id,
            title: String(world.name.prefix(GameCatalogue.Limits.maximumTitleLength)),
            author: String(author.prefix(GameCatalogue.Limits.maximumAuthorLength)),
            summary: "",
            world: "games/\(id)/world.ablox",
            cover: "games/\(id)/cover.png",
            tags: [],
            blockCount: world.blocks.count,
            maxPlayers: 4,
            schemaVersion: world.schemaVersion,
            updatedAt: world.modifiedAt
        )
    }

    /// This listing as the JSON to paste into `index.json`.
    func indexEntryJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// The first reason this listing cannot be shown, or nil if it is fine.
    func rejection(alreadySeen: Set<String> = []) -> CatalogueRejection? {
        typealias Limits = GameCatalogue.Limits

        guard Limits.isValidID(id) else { return .invalidID(id) }
        guard !alreadySeen.contains(id) else { return .duplicateID(id) }

        guard !title.isEmpty, title.count <= Limits.maximumTitleLength else {
            return .fieldTooLong(field: "title", limit: Limits.maximumTitleLength)
        }
        guard author.count <= Limits.maximumAuthorLength else {
            return .fieldTooLong(field: "author", limit: Limits.maximumAuthorLength)
        }
        guard summary.count <= Limits.maximumSummaryLength else {
            return .fieldTooLong(field: "summary", limit: Limits.maximumSummaryLength)
        }
        guard tags.count <= Limits.maximumTags,
              tags.allSatisfy({ !$0.isEmpty && $0.count <= Limits.maximumTagLength })
        else {
            return .fieldTooLong(field: "tags", limit: Limits.maximumTagLength)
        }

        guard Limits.isValidRepositoryPath(world, extensions: Limits.worldExtensions) else {
            return .invalidPath(field: "world", value: world)
        }
        if let cover {
            guard Limits.isValidRepositoryPath(cover, extensions: Limits.coverExtensions) else {
                return .invalidPath(field: "cover", value: cover)
            }
        }

        guard schemaVersion >= 1 else { return .unsupportedSchema(id: id, schemaVersion: schemaVersion) }
        guard isSupported else { return .unsupportedSchema(id: id, schemaVersion: schemaVersion) }

        return nil
    }

    /// Checks a downloaded world against what its listing promised.
    ///
    /// Not a security boundary — the world has already been decoded by then,
    /// and the limits that matter were applied to the bytes. This catches the
    /// ordinary case of an index that was edited by hand and never updated,
    /// so the list can stop showing a block count that is a year out of date.
    func mismatch(with world: WorldDocument) -> String? {
        if world.blocks.count != blockCount {
            return L("The listing says {} parts but the world has {}.", blockCount, world.blocks.count)
        }
        return nil
    }
}

// MARK: - Where the files live

/// Turns repository-relative paths into URLs, and nothing else.
///
/// Separate from the networking layer so the URL arithmetic — the part where a
/// mistake means fetching from the wrong host — is testable without a socket.
public struct CatalogueSource: Equatable, Sendable {

    /// The repository the app reads from, as `owner/repo`.
    public var repository: String
    /// The branch or tag to read. A tag would pin the catalogue; the default
    /// branch means a merged pull request is live immediately.
    public var reference: String

    public init(repository: String, reference: String = "main") {
        self.repository = repository
        self.reference = reference
    }

    /// The default the app ships with.
    public static let `default` = CatalogueSource(repository: "prak59459-create/ablox-games")

    /// `raw.githubusercontent.com` rather than the API: no token, no rate
    /// limit worth worrying about, and the response is the file itself rather
    /// than JSON wrapping base64 of the file.
    public var baseURL: URL? {
        guard isValidRepository else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(repository)/\(reference)/")
    }

    public var indexURL: URL? {
        baseURL.map { $0.appendingPathComponent("index.json") }
    }

    /// The URL for a path a listing gave us.
    ///
    /// Returns nil rather than a wrong URL for anything that does not pass
    /// `isValidRepositoryPath`, so a caller that forgets to validate still
    /// cannot be pointed at another host.
    public func url(forPath path: String, extensions: [String]) -> URL? {
        guard GameCatalogue.Limits.isValidRepositoryPath(path, extensions: extensions),
              let baseURL
        else { return nil }

        // Built by appending components rather than by string concatenation:
        // `appendingPathComponent` percent-encodes each one, so a space or a
        // non-ASCII character in a folder name cannot produce an invalid URL.
        return path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    public func worldURL(for listing: GameListing) -> URL? {
        url(forPath: listing.world, extensions: GameCatalogue.Limits.worldExtensions)
    }

    public func coverURL(for listing: GameListing) -> URL? {
        listing.cover.flatMap { url(forPath: $0, extensions: GameCatalogue.Limits.coverExtensions) }
    }

    /// The page a person can open to read the repository or submit to it.
    public var webURL: URL? {
        isValidRepository ? URL(string: "https://github.com/\(repository)") : nil
    }

    /// `owner/repo`, both plausible GitHub names.
    ///
    /// Checked because this is settable: someone typing their own catalogue
    /// into Settings must not be able to aim the app at an arbitrary URL by
    /// putting a slash or a scheme in the box.
    public var isValidRepository: Bool {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.count <= 100
                && part.first != "."
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        }
    }
}
