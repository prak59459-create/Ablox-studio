import Foundation

// Keeping leaderboards, in a file of its own, split from
// WorldFeatures.swift: a change here rebuilds only the files that use what
// is here, not every file that uses anything that was declared beside it.

/// A world's leaderboards on the host's iPad: one small file per world, in
/// Application Support/Leaderboards. Whoever hosts keeps their own — there is
/// no server to hold one for everybody.
public struct LeaderboardStore: Sendable {
    public let directory: URL

    public init(directory: URL = LeaderboardStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Leaderboards", isDirectory: true)
    }

    private func url(for worldID: UUID) -> URL {
        directory.appendingPathComponent(worldID.uuidString).appendingPathExtension("json")
    }

    public func load(worldID: UUID) -> [String: Leaderboard] {
        guard let data = try? Data(contentsOf: url(for: worldID)),
              let boards = try? JSONDecoder().decode([String: Leaderboard].self, from: data) else { return [:] }
        return boards
    }

    public func save(_ boards: [String: Leaderboard], worldID: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(boards) else { return }
        try? data.write(to: url(for: worldID), options: .atomic)
    }

    public func delete(worldID: UUID) {
        try? FileManager.default.removeItem(at: url(for: worldID))
    }
}
