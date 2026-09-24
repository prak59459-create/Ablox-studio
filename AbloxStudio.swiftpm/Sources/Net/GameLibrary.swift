import Foundation
import Combine

/// Downloads and caches the published game catalogue.
///
/// Thin on purpose. Every decision worth getting right — what a path is
/// allowed to be, how big a download may be, which listings are usable — lives
/// in `GameCatalogue` in the portable core, where it is tested. What is left
/// here is `URLSession` calls and files on disk, which this project cannot
/// compile off-device and therefore cannot check.
///
/// ## Offline first
///
/// The cache is the source of truth for what is *shown*. A refresh updates it;
/// a failed refresh leaves the last good catalogue on screen with a quiet
/// note, because an iPad in a classroom is offline more often than not and an
/// empty list would look like the feature is broken.
@MainActor
public final class GameLibrary: ObservableObject {

    public enum Status: Equatable {
        case idle
        case refreshing
        /// Showing the cache because the network did not answer.
        case offline(String)
        case failed(String)
    }

    @Published public private(set) var listings: [GameListing] = []
    @Published public private(set) var status: Status = .idle
    /// Ids whose world file is already on disk.
    @Published public private(set) var installed: Set<String> = []
    /// When the catalogue last changed, for the "last updated" line.
    @Published public private(set) var updatedAt: Date?

    /// Which repository to read. Settable so a school can run its own.
    @Published public var source: CatalogueSource {
        didSet {
            if source != oldValue {
                listings = []
                updatedAt = nil
                fallbackBranch = nil
            }
        }
    }

    /// The repository's default branch, when the chosen branch had no
    /// `index.json` and that one did. Worlds, scripts and covers then come
    /// from the same place the list did.
    private var fallbackBranch: String?

    /// Where the list — and everything it points to — was actually read.
    public var effectiveSource: CatalogueSource {
        fallbackBranch.map { source.on(branch: $0) } ?? source
    }

    private let session: URLSession
    private let cacheDirectory: URL
    private var coverCache: [String: Data] = [:]

    public init(source: CatalogueSource = .default, session: URLSession = .shared) {
        self.source = source
        self.session = session

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = base.appendingPathComponent("ablox-catalogue", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        loadCachedIndex()
        refreshInstalledList()
    }

    // MARK: Refresh

    public func refresh() async {
        guard let url = source.indexURL else {
            status = .failed(L("That catalogue address is not a GitHub repository."))
            return
        }

        status = .refreshing
        do {
            let data: Data
            do {
                data = try await fetch(url, limit: GameCatalogue.Limits.maximumIndexBytes)
                fallbackBranch = nil
            } catch FetchError.badStatus(404) {
                // Nothing on that branch — most often a repository with no
                // `main`. Its default branch is the next best guess.
                guard let branch = await defaultBranch(), branch != source.reference,
                      let fallbackURL = source.on(branch: branch).indexURL else {
                    status = .failed(L("There is no game list on the branch “{}” of {}. Check the repository and branch in Settings.",
                                       source.reference, source.repository))
                    return
                }
                data = try await fetch(fallbackURL, limit: GameCatalogue.Limits.maximumIndexBytes)
                fallbackBranch = branch
            }
            let catalogue = try GameCatalogue.decode(indexData: data)
            apply(catalogue)
            // Written only after it parsed, so a corrupt response cannot
            // replace a cache that still works.
            try? data.write(to: indexCacheURL, options: .atomic)
            status = .idle
        } catch let error as CatalogueError {
            status = .failed(error.message)
        } catch {
            // Keep whatever the cache gave us on screen.
            status = listings.isEmpty
                ? .failed(L("Could not reach the game list."))
                : .offline(L("Showing the games saved on this iPad."))
        }
    }

    private func apply(_ catalogue: GameCatalogue) {
        let result = catalogue.validated()
        listings = result.accepted
        updatedAt = catalogue.updatedAt

        #if DEBUG
        for (id, reason) in result.rejected {
            print("[catalogue] skipped \(id): \(reason)")
        }
        #endif
    }

    private func loadCachedIndex() {
        guard let data = try? Data(contentsOf: indexCacheURL),
              let catalogue = try? GameCatalogue.decode(indexData: data)
        else { return }
        apply(catalogue)
    }

    // MARK: Downloading a world

    /// Fetches a world, verifies it, and saves it under the app's worlds.
    ///
    /// Returns the document so the caller can open it straight away. A world
    /// that fails any check is not written at all — a half-written file that
    /// fails to open later is worse than a download that visibly failed.
    public func download(_ listing: GameListing) async -> WorldDocument? {
        guard listing.rejection() == nil else {
            status = .failed(L("That game's listing is malformed."))
            return nil
        }
        guard let url = effectiveSource.worldURL(for: listing) else {
            status = .failed(L("That game's listing is malformed."))
            return nil
        }

        do {
            let data = try await fetch(url, limit: GameCatalogue.Limits.maximumWorldBytes)
            var world = try WorldDocument.decoded(from: data)

            guard world.blocks.count <= GameCatalogue.Limits.maximumBlocks else {
                status = .failed(L("That world has too many parts to open safely."))
                return nil
            }

            // A fresh id, so downloading a game twice — or downloading one
            // whose id collides with a world already on this iPad — does not
            // overwrite anything the player made.
            world.id = UUID()

            // `.absc` files kept beside the world in the repository. One with
            // the same name as a script inside the world replaces it, so the
            // repository copy is the one that counts.
            var scripts: [(name: String, source: String)] = []
            for script in effectiveSource.scriptURLs(for: listing) {
                let bytes = try await fetch(script.url, limit: GameCatalogue.Limits.maximumScriptBytes)
                guard let text = String(data: bytes, encoding: .utf8) else { continue }
                scripts.append((name: script.name, source: text))
            }
            world.scripts = ScriptSource.merge(scripts, into: world.scripts).files

            let destination = worldCacheURL(for: listing.id)
            try world.encodedForFile().write(to: destination, options: .atomic)
            refreshInstalledList()
            status = .idle
            return world
        } catch {
            status = .failed(L("Could not download “{}”.", listing.title))
            return nil
        }
    }

    /// The cached world for a listing already downloaded, if there is one.
    public func cachedWorld(for listing: GameListing) -> WorldDocument? {
        guard let data = try? Data(contentsOf: worldCacheURL(for: listing.id)) else { return nil }
        return try? WorldDocument.decoded(from: data)
    }

    // MARK: Covers

    /// Cover image bytes, from memory, then disk, then the network.
    ///
    /// Returns `nil` rather than an error for anything that goes wrong: a
    /// missing picture is a placeholder in the list, never a message.
    public func coverData(for listing: GameListing) async -> Data? {
        let key = coverKey(for: listing)
        if let cached = coverCache[key] { return cached }

        let fileURL = coverCacheURL(forKey: key)
        if let data = try? Data(contentsOf: fileURL) {
            coverCache[key] = data
            return data
        }

        guard let url = effectiveSource.coverURL(for: listing) else { return nil }
        guard let data = try? await fetch(url, limit: GameCatalogue.Limits.maximumCoverBytes) else { return nil }

        coverCache[key] = data
        removeOldCovers(of: listing.id, keeping: fileURL)
        try? data.write(to: fileURL, options: .atomic)
        return data
    }

    // MARK: Cache

    public func isInstalled(_ listing: GameListing) -> Bool {
        installed.contains(listing.id)
    }

    /// Deletes everything downloaded. The player's own worlds are elsewhere
    /// and are not touched.
    public func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        coverCache.removeAll()
        listings = []
        updatedAt = nil
        refreshInstalledList()
    }

    public var cacheSizeInBytes: Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func refreshInstalledList() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            installed = []
            return
        }
        installed = Set(
            files
                .filter { $0.lastPathComponent.hasSuffix(".ablox") }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    private var indexCacheURL: URL {
        cacheDirectory.appendingPathComponent("index.json")
    }

    /// Built from the listing id, which `GameCatalogue.Limits.isValidID` has
    /// already restricted to lowercase ASCII with no separators — so this
    /// cannot become a path outside the cache directory.
    private func worldCacheURL(for id: String) -> URL {
        cacheDirectory.appendingPathComponent("\(id).ablox")
    }

    /// The game and its cover's path. The catalogue publishes a changed
    /// picture under a new file name, so keying on the path fetches the new
    /// one instead of showing the first copy ever downloaded forever.
    ///
    /// `@` cannot appear in an id, so one game's key is never the start of
    /// another's.
    private func coverKey(for listing: GameListing) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (listing.cover ?? "").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return "\(listing.id)@\(String(hash, radix: 16))"
    }

    private func coverCacheURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).cover")
    }

    /// Earlier covers of the same game, and the unkeyed file older builds
    /// wrote.
    private func removeOldCovers(of id: String, keeping current: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        for name in names where name == "\(id).cover" || (name.hasPrefix("\(id)@") && name.hasSuffix(".cover")) {
            let url = cacheDirectory.appendingPathComponent(name)
            if url.lastPathComponent != current.lastPathComponent {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Fetching

    /// The repository's default branch according to GitHub, or nil.
    private func defaultBranch() async -> String? {
        guard let url = source.repositoryInfoURL,
              let data = try? await fetch(url, limit: CatalogueSource.maximumRepositoryInfoBytes) else { return nil }
        return CatalogueSource.defaultBranch(fromRepositoryInfo: data)
    }

    private enum FetchError: Error { case tooLarge, badStatus(Int) }

    /// One GET, with the response size held to `limit`.
    ///
    /// Checked twice: `expectedContentLength` refuses an honest large file
    /// before it is transferred, and the byte count refuses a response that
    /// lied about its length or did not declare one.
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        // The catalogue is small and changes rarely; letting the URL cache
        // answer keeps a list that is scrolled repeatedly off the network.
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw FetchError.badStatus(http.statusCode)
            }
        }
        if response.expectedContentLength > Int64(limit) {
            throw FetchError.tooLarge
        }
        guard data.count <= limit else { throw FetchError.tooLarge }

        return data
    }
}
