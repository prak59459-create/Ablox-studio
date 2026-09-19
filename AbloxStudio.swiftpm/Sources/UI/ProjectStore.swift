import Foundation
import Combine

/// On-disk library of worlds.
///
/// Worlds are individual JSON files in Application Support rather than rows in
/// a database, so a world is a thing you can hand to someone. One file, one
/// world, readable if you open it.
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

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var lastError: String?

    private let directory: URL
    private let fileManager = FileManager.default

    public init(directoryName: String = "Worlds") {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = base.appendingPathComponent(directoryName, isDirectory: true)
        createDirectoryIfNeeded()
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
    }

    /// Reads just enough of a world file to list it.
    ///
    /// A corrupt or half-written file is skipped rather than failing the whole
    /// listing — one bad world must not hide the other nine.
    private func entry(for url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url),
              let world = try? WorldDocument.decoded(from: data) else { return nil }
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
        do {
            return try WorldDocument.decoded(from: Data(contentsOf: entry.url))
        } catch {
            lastError = "Could not open “\(entry.name)”: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    public func save(_ world: WorldDocument) -> Bool {
        var world = world
        world.modifiedAt = Date()

        let url = fileURL(for: world.id)
        do {
            let data = try world.encodedForFile()
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

    public func delete(_ entry: Entry) {
        do {
            try fileManager.removeItem(at: entry.url)
            reload()
        } catch {
            lastError = "Could not delete “\(entry.name)”: \(error.localizedDescription)"
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

    /// Exposed so the Studio can offer "share this world" via the system
    /// share sheet.
    public func url(for world: WorldDocument) -> URL {
        fileURL(for: world.id)
    }
}
