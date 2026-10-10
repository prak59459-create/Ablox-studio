import Foundation
import Combine
import CryptoKit
import AbloxCore

/// The sound library on this iPad: its list, the files already downloaded,
/// and "download every sound".
///
/// The list is `sounds/index.json` in the game list repository, read from the
/// same repository and branch as the games (`source`). Files come from the
/// same place, one at a time when a game first plays one, or all of them at
/// once from the Sound library screen, and each is kept only when its size
/// and SHA-256 are the ones the list gives — so a file can also safely come
/// from SFXMint itself when GitHub does not have it.
///
/// Files are kept in Application Support, out of iCloud backups (they can
/// always be downloaded again), until "Delete downloaded sounds".
@MainActor
public final class SoundLibraryStore: ObservableObject {
    public static let shared = SoundLibraryStore()

    public enum Status: Equatable {
        case idle
        case loading
        case offline(String)
        case failed(String)
    }

    @Published public private(set) var library: SoundLibrary?
    @Published public private(set) var status: Status = .idle
    /// Ids of the sounds on this iPad.
    @Published public private(set) var installed: Set<String> = []
    @Published public private(set) var installedBytes = 0
    /// Sounds coming down one by one (not in a bulk run).
    @Published public private(set) var downloading: Set<String> = []
    /// "Download every sound", while it runs and after it has finished.
    @Published public private(set) var bulk: BulkDownload?
    /// The category a bulk run is for; nil for every sound.
    @Published public private(set) var bulkCategory: String?

    /// Which repository and branch to read; the game list's.
    public var source: CatalogueSource = .default {
        didSet {
            if source != oldValue { fallbackBranch = nil; lastRefresh = nil }
        }
    }

    private var fallbackBranch: String?
    private var lastRefresh: Date?
    private var bulkTask: Task<Void, Never>?
    private var loading: [String: Task<SoundClip?, Never>] = [:]
    private let session: URLSession
    private let directory: URL

    public var effectiveSource: CatalogueSource {
        fallbackBranch.map { source.on(branch: $0) } ?? source
    }

    public var isDownloadingAll: Bool { bulkTask != nil }

    init(session: URLSession = .shared) {
        self.session = session
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("AbloxSounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL), let cached = try? SoundLibrary.decode(indexData: data) {
            library = cached
        }
        rescan()
    }

    // MARK: The list

    /// Fetches the list unless it was fetched in the last half hour.
    public func refreshIfStale() async {
        if library != nil, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 * 60 { return }
        await refresh()
    }

    public func refresh() async {
        guard let url = source.url(forPath: SoundLibrary.Limits.indexPath, extensions: ["json"]) else {
            status = .failed(L("That catalogue address is not a GitHub repository."))
            return
        }
        status = .loading
        do {
            let data: Data
            do {
                data = try await fetch(url, limit: SoundLibrary.Limits.maximumIndexBytes)
                fallbackBranch = nil
            } catch FetchError.badStatus(404) {
                // Nothing on that branch: the repository's default branch
                // is the next best guess, as for the game list.
                guard let branch = await defaultBranch(), branch != source.reference,
                      let other = source.on(branch: branch).url(forPath: SoundLibrary.Limits.indexPath, extensions: ["json"]) else {
                    status = .failed(L("There is no sound library on the branch “{}” of {}. Check the game list's repository and branch in Settings.",
                                       source.reference, source.repository))
                    return
                }
                data = try await fetch(other, limit: SoundLibrary.Limits.maximumIndexBytes)
                fallbackBranch = branch
            }
            let fresh = try SoundLibrary.decode(indexData: data)
            library = fresh
            try? data.write(to: indexURL, options: .atomic)
            lastRefresh = Date()
            rescan()
            status = .idle
        } catch let error as SoundLibraryError {
            status = .failed(error.message)
        } catch {
            status = library == nil
                ? .failed(L("Could not reach the sound library."))
                : .offline(L("Showing the sound list saved on this iPad."))
        }
    }

    // MARK: Sounds

    public func isInstalled(_ id: String) -> Bool { installed.contains(id) }

    /// A sound ready to play: from memory, from this iPad, or downloaded
    /// now. Nil when it is not in the library or cannot be had.
    func clip(for id: String) async -> SoundClip? {
        if let clip = SoundClipCache.shared.clip(for: id) { return clip }
        if let running = loading[id] { return await running.value }
        let task = Task<SoundClip?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.load(id)
        }
        loading[id] = task
        let clip = await task.value
        loading[id] = nil
        return clip
    }

    private func load(_ id: String) async -> SoundClip? {
        let file = fileURL(for: id)
        if !installed.contains(id) {
            if library == nil { await refresh() }
            guard let sound = library?.sound(id), await download(sound) else { return nil }
        }
        let clip = await Task.detached(priority: .userInitiated) { SoundClipDecoder.clip(contentsOf: file) }.value
        if let clip { SoundClipCache.shared.store(clip, for: id) }
        return clip
    }

    /// Gets a game's sounds ready before it needs them.
    public func prepare(_ ids: [String]) async {
        if library == nil, ids.contains(where: { !installed.contains($0) }) { await refresh() }
        for id in ids.prefix(80) where library?.sound(id) != nil || installed.contains(id) {
            _ = await clip(for: id)
        }
    }

    /// Plays a sound for the Sound library screen.
    public func preview(_ sound: SoundLibrary.Sound) async {
        guard let clip = await clip(for: sound.id) else { return }
        SoundSynth.shared.play(clip)
    }

    /// Downloads one sound. True when it is on this iPad afterwards.
    @discardableResult
    public func download(_ sound: SoundLibrary.Sound) async -> Bool {
        if installed.contains(sound.id) { return true }
        downloading.insert(sound.id)
        defer { downloading.remove(sound.id) }
        let ok = await Self.fetchVerified(sound, from: effectiveSource, to: fileURL(for: sound.id), session: session)
        if ok {
            installed.insert(sound.id)
            installedBytes += sound.bytes
        }
        return ok
    }

    // MARK: Every sound

    /// Downloads every sound not on this iPad yet — or every one in
    /// `category` — six at a time. Nothing happens if a run is going.
    public func downloadAll(category: String? = nil) {
        guard bulkTask == nil, let library else { return }
        let pool = category.map { library.families(in: $0) } ?? library.families
        let missing = pool.flatMap(\.sounds).filter { !installed.contains($0.id) }
        bulk = BulkDownload(total: missing.count, expectedBytes: missing.reduce(0) { $0 + $1.bytes })
        bulkCategory = category
        guard !missing.isEmpty else {
            bulk?.finished = true
            return
        }
        let from = effectiveSource
        let session = self.session
        let destination = directory
        bulkTask = Task { [weak self] in
            await withTaskGroup(of: (SoundLibrary.Sound, Bool).self) { group in
                var queue = missing.makeIterator()
                for _ in 0..<6 {
                    guard let sound = queue.next() else { break }
                    group.addTask {
                        (sound, await Self.fetchVerified(sound, from: from, to: Self.file(for: sound.id, in: destination), session: session))
                    }
                }
                var done = 0, failed = 0, bytes = 0
                var arrived: [SoundLibrary.Sound] = []
                var lastReport = Date()
                while let (sound, ok) = await group.next() {
                    done += 1
                    if ok { bytes += sound.bytes; arrived.append(sound) } else { failed += 1 }
                    if Date().timeIntervalSince(lastReport) > 0.25 || done == missing.count {
                        lastReport = Date()
                        self?.report(done: done, failed: failed, bytes: bytes, current: sound.id, arrived: arrived)
                        arrived.removeAll(keepingCapacity: true)
                    }
                    if !Task.isCancelled, let next = queue.next() {
                        group.addTask {
                            (next, await Self.fetchVerified(next, from: from, to: Self.file(for: next.id, in: destination), session: session))
                        }
                    }
                }
                self?.report(done: done, failed: failed, bytes: bytes, current: nil, arrived: arrived)
            }
            self?.finishBulk()
        }
    }

    private func report(done: Int, failed: Int, bytes: Int, current: String?, arrived: [SoundLibrary.Sound]) {
        // Assigned once, so the screen redraws once for the lot.
        var ids = installed
        var added = 0
        for sound in arrived where ids.insert(sound.id).inserted { added += sound.bytes }
        if added > 0 {
            installed = ids
            installedBytes += added
        }
        bulk?.done = done
        bulk?.failed = failed
        bulk?.bytes = bytes
        bulk?.current = current
    }

    /// Stops "download every sound" after the files coming down now.
    public func cancelAll() {
        guard let bulkTask else { return }
        bulkTask.cancel()
        bulk?.cancelled = true
    }

    /// Puts away the "finished" note.
    public func dismissBulk() {
        if bulkTask == nil {
            bulk = nil
            bulkCategory = nil
        }
    }

    private func finishBulk() {
        bulk?.current = nil
        bulk?.finished = true
        bulkTask = nil
    }

    /// Deletes every downloaded sound. The list stays; a game that plays
    /// one downloads it again.
    public func removeAll() {
        cancelAll()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".mp3") || name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        SoundClipCache.shared.removeAll()
        rescan()
    }

    // MARK: Files

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func fileURL(for id: String) -> URL { Self.file(for: id, in: directory) }

    /// `id` has passed `SoundLibrary.isLibraryID` (lowercase letters,
    /// digits and hyphens), so this cannot leave the folder.
    nonisolated static func file(for id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id).mp3")
    }

    private func rescan() {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var ids = Set<String>()
        var total = 0
        for url in files where url.pathExtension == "mp3" {
            ids.insert(url.deletingPathExtension().lastPathComponent)
            total += (try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0
        }
        installed = ids
        installedBytes = total
    }

    // MARK: Fetching

    private enum FetchError: Error { case tooLarge, badStatus(Int) }

    /// Downloads a sound from the game list repository — or from SFXMint,
    /// where it came from, when the repository does not answer with it —
    /// and writes it only if it is exactly the file the list describes.
    nonisolated static func fetchVerified(_ sound: SoundLibrary.Sound, from source: CatalogueSource, to file: URL,
                                          session: URLSession) async -> Bool {
        var places: [URL] = []
        if let url = source.url(forPath: sound.path, extensions: ["mp3"]) { places.append(url) }
        if let original = URL(string: "https://sfxmint.com/dl/\(sound.id).mp3") { places.append(original) }
        for url in places {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true,
                  data.count == sound.bytes else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == sound.sha256 else { continue }
            do {
                try data.write(to: file, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    private func defaultBranch() async -> String? {
        guard let url = source.repositoryInfoURL,
              let data = try? await fetch(url, limit: CatalogueSource.maximumRepositoryInfoBytes) else { return nil }
        return CatalogueSource.defaultBranch(fromRepositoryInfo: data)
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        guard data.count <= limit else { throw FetchError.tooLarge }
        return data
    }
}
