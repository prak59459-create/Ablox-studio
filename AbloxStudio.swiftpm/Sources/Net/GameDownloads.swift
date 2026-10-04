import Foundation
import Combine

/// What is downloading from the game list, and how many megabytes have come
/// down — shared by every Games tab.
///
/// The Games tab makes a new `GameLibrary` each time it opens, so the
/// progress cannot live there: leaving the tab in the middle of "download
/// every game" and coming back must still show it going. `GameLibrary`
/// reports each game's bytes here as they arrive; the views read from here.
@MainActor
public final class GameDownloads: ObservableObject {
    public static let shared = GameDownloads()

    /// Games coming down now, by listing id.
    @Published public private(set) var games: [String: DownloadMeter] = [:]
    /// "Download every game", while it runs and after it has finished.
    @Published public private(set) var bulk: BulkDownload?
    /// Goes up each time a download ends, so a library re-reads what is on
    /// the iPad.
    @Published public private(set) var endedCount = 0

    private var bulkTask: Task<Void, Never>?
    /// The bulk run's current game, whose bytes add to the run's total.
    private var bulkGame: String?

    public var isDownloadingAll: Bool { bulkTask != nil }

    // MARK: Reports from GameLibrary

    func began(_ id: String, expected: Int?) {
        games[id] = DownloadMeter(expected: expected)
        if bulkGame == id { bulk?.currentMeter = DownloadMeter(expected: expected) }
    }

    func received(_ id: String, bytes: Int, expected: Int?) {
        // Reports hop to the main actor one by one and can arrive out of
        // order; the count only ever goes up.
        guard let old = games[id], bytes > old.received else { return }
        let meter = DownloadMeter(received: bytes, expected: expected ?? old.expected)
        games[id] = meter
        if bulkGame == id {
            bulk?.bytes += bytes - old.received
            bulk?.currentMeter = meter
        }
    }

    /// `total`: every byte the game took, so the last piece still counts
    /// if its report has not arrived yet.
    func ended(_ id: String, total: Int) {
        if bulkGame == id, let old = games[id], total > old.received {
            bulk?.bytes += total - old.received
        }
        games[id] = nil
        endedCount += 1
    }

    // MARK: Every game

    /// Downloads every game on `library`'s list that is not on this iPad
    /// yet, one after another. Nothing happens if a run is already going.
    public func downloadAll(with library: GameLibrary) {
        guard bulkTask == nil else { return }
        let missing = library.listings.filter { !library.isInstalled($0) && $0.isSupported }
        let sizes = missing.compactMap(\.downloadSize)
        bulk = BulkDownload(total: missing.count, expectedBytes: sizes.count == missing.count ? sizes.reduce(0, +) : nil)
        guard !missing.isEmpty else {
            bulk?.finished = true
            return
        }
        bulkTask = Task { [weak self] in
            for listing in missing {
                if Task.isCancelled { break }
                self?.bulkGame = listing.id
                self?.bulk?.current = listing.title
                self?.bulk?.currentMeter = DownloadMeter(expected: listing.downloadSize)
                let world = await library.download(listing)
                if Task.isCancelled { break }
                _ = await library.coverData(for: listing)
                self?.bulk?.done += 1
                if world == nil { self?.bulk?.failed += 1 }
            }
            self?.finishBulk()
        }
    }

    /// Stops "download every game" after the game coming down now. What
    /// already came down stays.
    public func cancelAll() {
        guard let bulkTask else { return }
        bulkTask.cancel()
        bulk?.cancelled = true
    }

    /// Puts away the "finished" note.
    public func dismissBulk() {
        if bulkTask == nil { bulk = nil }
    }

    private func finishBulk() {
        bulkGame = nil
        bulk?.current = nil
        bulk?.finished = true
        bulkTask = nil
    }
}
