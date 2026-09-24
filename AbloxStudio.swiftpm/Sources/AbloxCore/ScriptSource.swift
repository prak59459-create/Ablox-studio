import Foundation

/// Where a world's `.absc` files live on GitHub.
///
/// Scripts are easier to write on a computer, and a repository is where a
/// computer keeps them. With this set, Studio pulls every `.absc` in the folder
/// into the world with one button — and, when `updatesOnPlay` is on, the host
/// pulls them again every time the game starts, so pushing a fix to the
/// repository fixes the game for everyone without publishing it again.
///
/// Like the game list, this only ever *reads*, from public repositories, and
/// everything it reads is treated as written by a stranger: the names become
/// file names, the sizes are checked, and the URLs are built here rather than
/// taken from the response.
public struct ScriptSource: Codable, Hashable, Sendable {
    /// `owner/repo`.
    public var repository: String
    public var branch: String
    /// A folder inside the repository, or empty for the top level.
    public var folder: String
    /// Pull the latest files each time the game is hosted.
    public var updatesOnPlay: Bool

    public init(repository: String, branch: String = "main", folder: String = "", updatesOnPlay: Bool = false) {
        self.repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.folder = folder
        self.updatesOnPlay = updatesOnPlay
    }

    public enum Limits {
        /// The folder listing. A thousand entries is well under this.
        public static let maximumListingBytes = 1024 * 1024
        public static let maximumFileBytes = GameCatalogue.Limits.maximumScriptBytes
    }

    /// The folder with stray slashes and spaces taken off.
    public var cleanFolder: String {
        folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
    }

    private var catalogueSource: CatalogueSource {
        CatalogueSource(repository: repository, reference: branch)
    }

    public var isValid: Bool {
        catalogueSource.isValidRepository && CatalogueSource.isValidReference(branch) && Self.isValidFolder(cleanFolder)
    }

    /// `owner/repo@branch/folder`, for showing what is set.
    public var displayName: String {
        let base = "\(repository)@\(branch)"
        return cleanFolder.isEmpty ? base : "\(base)/\(cleanFolder)"
    }

    /// A folder inside the repository and nowhere else: no climbing out, no
    /// hidden folders, nothing a URL would read as something other than a path.
    public static func isValidFolder(_ folder: String) -> Bool {
        guard folder.count <= GameCatalogue.Limits.maximumPathLength else { return false }
        guard !folder.isEmpty else { return true }
        guard !folder.contains("\\"), !folder.contains(":"), !folder.contains("?"),
              !folder.contains("#"), !folder.contains("%"), !folder.contains("\0") else { return false }
        return folder.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
        }
    }

    /// GitHub's listing of the folder. The one call that needs the API: a
    /// raw file server has no way to say what is in a folder.
    public var listingURL: URL? {
        guard isValid else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/contents" + (cleanFolder.isEmpty ? "" : "/\(cleanFolder)")
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        return components.url
    }

    /// Where one file's text is, built from the name rather than taken from
    /// the listing — so a listing cannot point the download anywhere else.
    public func fileURL(named name: String) -> URL? {
        guard isValid, name == ScriptFile.cleanName(name) else { return nil }
        let path = cleanFolder.isEmpty ? name : "\(cleanFolder)/\(name)"
        return catalogueSource.url(forPath: path, extensions: GameCatalogue.Limits.scriptExtensions)
    }

    // MARK: Reading the listing

    public struct RemoteFile: Equatable, Sendable {
        public let name: String
        public let size: Int
    }

    public enum ListingError: Error, Equatable, Sendable {
        /// The path is a file, or the response was not a folder listing.
        case notAFolder
        case malformed
        case tooLarge

        public var message: String {
            switch self {
            case .notAFolder: return L("That path is not a folder in the repository.")
            case .malformed: return L("GitHub's answer could not be read.")
            case .tooLarge: return L("That download was too big and was refused.")
            }
        }
    }

    /// The `.absc` files in a GitHub contents-API folder listing.
    ///
    /// Anything that is not a file, not `.absc`, too big, or named something
    /// that would change on the way to becoming a file name is left out.
    public static func parseListing(_ data: Data) throws -> [RemoteFile] {
        guard data.count <= Limits.maximumListingBytes else { throw ListingError.tooLarge }

        struct Entry: Decodable {
            let name: String
            let type: String
            let size: Int?
        }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            // A single object is what GitHub sends for a file path.
            if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { throw ListingError.notAFolder }
            throw ListingError.malformed
        }

        let files = entries
            .filter { $0.type == "file" }
            .filter { $0.name.lowercased().hasSuffix(".\(ScriptFile.fileExtension)") }
            .filter { ScriptFile.cleanName($0.name) == $0.name }
            .filter { ($0.size ?? 0) <= Limits.maximumFileBytes }
            .map { RemoteFile(name: $0.name, size: $0.size ?? 0) }
            // Plain lowercased order, not the device's locale: the same
            // repository must pull the same files on every iPad.
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
        return Array(files.prefix(ScriptFile.Limits.maximumFiles))
    }
}

// MARK: - Bringing files in

/// What a pull changed, for the line Studio shows afterwards.
public struct ScriptSyncResult: Equatable, Sendable {
    public var added: [String] = []
    public var updated: [String] = []
    public var unchanged: [String] = []
    /// Not added because the world already had as many files as it may.
    public var skipped: [String] = []

    public init() {}

    public var changedAnything: Bool { !added.isEmpty || !updated.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append(L("Added {}", added.joined(separator: ", "))) }
        if !updated.isEmpty { parts.append(L("Updated {}", updated.joined(separator: ", "))) }
        if !skipped.isEmpty { parts.append(L("Skipped {} (too many files)", skipped.joined(separator: ", "))) }
        return parts.isEmpty ? L("Already up to date.") : parts.joined(separator: " · ")
    }
}

public extension ScriptSource {

    /// Folds downloaded files into a world's scripts.
    ///
    /// A file with the same name (ignoring case) is replaced, keeping its id
    /// and its on/off switch; a new name is added. Files the repository does
    /// not have are kept — a pull never deletes anything written on the iPad.
    static func merge(_ downloaded: [(name: String, source: String)], into files: [ScriptFile]) -> (files: [ScriptFile], result: ScriptSyncResult) {
        var merged = files
        var result = ScriptSyncResult()
        for file in downloaded {
            let name = ScriptFile.cleanName(file.name)
            if let index = merged.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                if merged[index].source == file.source {
                    result.unchanged.append(merged[index].name)
                } else {
                    merged[index].source = file.source
                    result.updated.append(merged[index].name)
                }
            } else if merged.count < ScriptFile.Limits.maximumFiles {
                merged.append(ScriptFile(name: name, source: file.source))
                result.added.append(name)
            } else {
                result.skipped.append(name)
            }
        }
        return (merged, result)
    }
}
