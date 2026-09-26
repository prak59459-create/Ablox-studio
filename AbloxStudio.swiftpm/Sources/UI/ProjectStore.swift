import Foundation
import Combine

/// On-disk library of worlds.
///
/// Worlds are individual JSON files in Application Support rather than rows in
/// a database, so a world is a thing you can hand to someone. One file, one
/// world, readable if you open it.
///
/// Three things stand between a child and losing a world:
/// - every write is atomic, so a crash mid-save leaves the last good file;
/// - older versions are kept (`Versions/<id>/`), one every few minutes, so a
///   world broken by an edit — or a file broken by the disk — can go back;
/// - deleting moves the world to `Recently Deleted/` for thirty days first.
@MainActor
public final class ProjectStore: ObservableObject {

    public struct Entry: Identifiable, Hashable {
        public let id: UUID
        public var name: String
        public var authorName: String
        public var modifiedAt: Date
        public var blockCount: Int
        public var url: URL

        public var subtitle: String {
            let parts = ["\(blockCount) part\(blockCount == 1 ? "" : "s")", Entry.relativeFormatter.localizedString(for: modifiedAt, relativeTo: Date())]
            return parts.joined(separator: " · ")
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter
        }()
    }

    /// A world that was deleted, still in Recently Deleted.
    public struct DeletedEntry: Identifiable, Hashable {
        public let id: UUID
        public let name: String
        public let deletedAt: Date
        public let blockCount: Int
        public let url: URL

        /// Days before it goes for good.
        public var daysLeft: Int {
            let left = ProjectStore.keepDeletedFor - Date().timeIntervalSince(deletedAt)
            return Swift.max(0, Int((left / 86_400).rounded(.up)))
        }
    }

    /// An earlier version of a world, kept automatically.
    public struct Version: Identifiable, Hashable {
        public var id: URL { url }
        public let url: URL
        public let savedAt: Date
        public let byteCount: Int
    }

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var deleted: [DeletedEntry] = []
    @Published public private(set) var lastError: String?

    /// A new version is kept at most this often. An editor autosaves every
    /// few seconds; a version per autosave would bury the one worth going
    /// back to.
    nonisolated public static let versionInterval: TimeInterval = 5 * 60
    nonisolated public static let maximumVersions = 20
    nonisolated public static let keepDeletedFor: TimeInterval = 30 * 86_400

    private let directory: URL
    private let versionsDirectory: URL
    private let trashDirectory: URL
    private let fileManager = FileManager.default

    public init(directoryName: String = "Worlds") {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = base.appendingPathComponent(directoryName, isDirectory: true)
        self.versionsDirectory = directory.appendingPathComponent("Versions", isDirectory: true)
        self.trashDirectory = directory.appendingPathComponent("Recently Deleted", isDirectory: true)
        createDirectoryIfNeeded()
        purgeExpiredDeletions()
        reload()
    }

    private func createDirectoryIfNeeded() {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not create the worlds folder: \(error.localizedDescription)"
        }
    }

    // MARK: Listing

    public func reload() {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == Self.fileExtension }

            entries = urls.compactMap(entry(for:)).sorted { $0.modifiedAt > $1.modifiedAt }
            lastError = nil
        } catch {
            entries = []
            lastError = "Could not read saved worlds: \(error.localizedDescription)"
        }
        deleted = deletedEntries()
    }

    /// Reads just enough of a world file to list it.
    ///
    /// A file that will not read is listed from its newest readable version
    /// instead, so a damaged world shows up — and opens — rather than
    /// silently vanishing; the next save puts a good file back. Only a world
    /// with nothing readable at all is skipped, and one bad world never hides
    /// the other nine.
    private func entry(for url: URL) -> Entry? {
        guard let world = readWorld(at: url) else { return nil }
        return Entry(
            id: world.id,
            name: world.name,
            authorName: world.authorName,
            modifiedAt: world.modifiedAt,
            blockCount: world.blocks.count,
            url: url
        )
    }

    // MARK: Load / save

    public func load(_ entry: Entry) -> WorldDocument? {
        if let world = readWorld(at: entry.url) { return world }
        lastError = "Could not open “\(entry.name)”."
        return nil
    }

    /// The world in `url`, or — when that file will not read — the newest of
    /// its kept versions that does.
    private func readWorld(at url: URL) -> WorldDocument? {
        if let data = try? Data(contentsOf: url), let world = try? WorldDocument.decoded(from: data) {
            return world
        }
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
        for version in versions(ofWorld: id) {
            if let data = try? Data(contentsOf: version.url), var world = try? WorldDocument.decoded(from: data) {
                world.id = id
                return world
            }
        }
        return nil
    }

    @discardableResult
    public func save(_ world: WorldDocument) -> Bool {
        save(world, keepingVersion: false)
    }

    @discardableResult
    private func save(_ world: WorldDocument, keepingVersion force: Bool) -> Bool {
        var world = world
        world.modifiedAt = Date()

        let url = fileURL(for: world.id)
        do {
            let data = try world.encodedForFile()
            // What is on disk now becomes a version before it is replaced.
            keepVersion(of: url, id: world.id, force: force)
            // Atomic: a crash mid-write leaves the previous version intact
            // rather than a truncated file that will not open.
            try data.write(to: url, options: [.atomic])
            reload()
            return true
        } catch {
            lastError = "Could not save “\(world.name)”: \(error.localizedDescription)"
            return false
        }
    }

    /// Moves the world to Recently Deleted, where it stays for thirty days.
    public func delete(_ entry: Entry) {
        do {
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let target = trashURL(for: entry.id)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: entry.url, to: target)
            // The file's date becomes the day it was deleted, which is what
            // the thirty days count from.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            reload()
        } catch {
            lastError = "Could not delete “\(entry.name)”: \(error.localizedDescription)"
        }
    }

    // MARK: Recently deleted

    private func deletedEntries() -> [DeletedEntry] {
        let urls = (try? fileManager.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }.compactMap { url -> DeletedEntry? in
            guard let data = try? Data(contentsOf: url), let world = try? WorldDocument.decoded(from: data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return DeletedEntry(id: world.id, name: world.name, deletedAt: date, blockCount: world.blocks.count, url: url)
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Puts a deleted world back in the library.
    public func restore(_ deletedEntry: DeletedEntry) {
        let target = fileURL(for: deletedEntry.id)
        do {
            if fileManager.fileExists(atPath: target.path) {
                // Something has taken its place since; keep both.
                guard var world = readWorld(at: deletedEntry.url) else { return }
                world.id = UUID()
                world.name = uniqueName(basedOn: world.name)
                save(world)
                try fileManager.removeItem(at: deletedEntry.url)
            } else {
                try fileManager.moveItem(at: deletedEntry.url, to: target)
            }
            reload()
        } catch {
            lastError = "Could not put back “\(deletedEntry.name)”: \(error.localizedDescription)"
        }
    }

    /// Gone for good, with its versions.
    public func deleteForever(_ deletedEntry: DeletedEntry) {
        try? fileManager.removeItem(at: deletedEntry.url)
        try? fileManager.removeItem(at: versionsFolder(for: deletedEntry.id))
        reload()
    }

    public func emptyRecentlyDeleted() {
        for item in deletedEntries() {
            try? fileManager.removeItem(at: item.url)
            try? fileManager.removeItem(at: versionsFolder(for: item.id))
        }
        reload()
    }

    private func purgeExpiredDeletions() {
        let cutoff = Date().addingTimeInterval(-Self.keepDeletedFor)
        for item in deletedEntries() where item.deletedAt < cutoff {
            try? fileManager.removeItem(at: item.url)
            try? fileManager.removeItem(at: versionsFolder(for: item.id))
        }
    }

    // MARK: Versions

    /// Earlier versions of a world, newest first.
    public func versions(of entry: Entry) -> [Version] {
        versions(ofWorld: entry.id)
    }

    private func versions(ofWorld id: UUID) -> [Version] {
        let folder = versionsFolder(for: id)
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { $0.pathExtension == Self.fileExtension }.compactMap { url -> Version? in
            guard let stamp = Double(url.deletingPathExtension().lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Version(url: url, savedAt: Date(timeIntervalSince1970: stamp / 1000), byteCount: size)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    /// Makes `version` the current world. What was current is kept as a
    /// version first, so going back can itself be undone.
    @discardableResult
    public func restore(_ version: Version, of entry: Entry) -> WorldDocument? {
        guard let data = try? Data(contentsOf: version.url), var world = try? WorldDocument.decoded(from: data) else {
            lastError = "That version of “\(entry.name)” could not be read."
            return nil
        }
        world.id = entry.id
        return save(world, keepingVersion: true) ? world : nil
    }

    /// Copies the file about to be replaced into the world's versions — unless
    /// the newest version is only a few minutes older than it.
    private func keepVersion(of url: URL, id: UUID, force: Bool) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let savedAt = ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? Date()
        let existing = versions(ofWorld: id)
        if !force, let newest = existing.first, savedAt.timeIntervalSince(newest.savedAt) < Self.versionInterval { return }
        let folder = versionsFolder(for: id)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int64((savedAt.timeIntervalSince1970 * 1000).rounded())
        let target = folder.appendingPathComponent(String(stamp)).appendingPathExtension(Self.fileExtension)
        guard !fileManager.fileExists(atPath: target.path) else { return }
        try? fileManager.copyItem(at: url, to: target)
        for old in versions(ofWorld: id).dropFirst(Self.maximumVersions) {
            try? fileManager.removeItem(at: old.url)
        }
    }

    public func duplicate(_ entry: Entry) {
        guard var world = load(entry) else { return }
        world.id = UUID()
        world.name = uniqueName(basedOn: "\(world.name) copy")
        world.createdAt = Date()
        save(world)
    }

    public func rename(_ entry: Entry, to newName: String) {
        guard var world = load(entry) else { return }
        world.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        save(world)
    }

    // MARK: Creating

    public func createWorld(named name: String, template: Template, author: String) -> WorldDocument {
        let unique = uniqueName(basedOn: name)
        let world: WorldDocument
        switch template {
        case .starter: world = .starter(named: unique, author: author)
        case .blank: world = .blank(named: unique, author: author)
        }
        save(world)
        return world
    }

    public enum Template: String, CaseIterable, Identifiable, Sendable {
        case starter
        case blank

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .starter: return L("Obstacle Course")
            case .blank: return L("Blank")
            }
        }

        public var detail: String {
            switch self {
            case .starter: return L("A floor, a spawn pad, stairs, a coin and a finish line. Tap Play and it already works.")
            case .blank: return L("Just a floor and a spawn point. Build from nothing.")
            }
        }

        public var symbolName: String {
            switch self {
            case .starter: return "figure.run"
            case .blank: return "square.dashed"
            }
        }
    }

    public func uniqueName(basedOn base: String) -> String {
        let existing = Set(entries.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Paths

    private static let fileExtension = "ablox"

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private func trashURL(for id: UUID) -> URL {
        trashDirectory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    private func versionsFolder(for id: UUID) -> URL {
        versionsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: Backups

    /// Every world, for a backup file.
    public func allWorlds() -> [WorldDocument] {
        entries.compactMap(load)
    }

    /// Worlds from a backup: new ones are added, and one already here is
    /// replaced only by a newer copy. Returns how many changed.
    @discardableResult
    public func merge(_ worlds: [WorldDocument]) -> Int {
        var changed = 0
        for world in worlds {
            if let existing = entries.first(where: { $0.id == world.id }), existing.modifiedAt >= world.modifiedAt { continue }
            let url = fileURL(for: world.id)
            do {
                keepVersion(of: url, id: world.id, force: true)
                try world.encodedForFile().write(to: url, options: [.atomic])
                changed += 1
            } catch {
                lastError = "Could not restore “\(world.name)”: \(error.localizedDescription)"
            }
        }
        reload()
        return changed
    }

    /// Exposed so the Studio can offer "share this world" via the system
    /// share sheet.
    public func url(for world: WorldDocument) -> URL {
        fileURL(for: world.id)
    }
}
