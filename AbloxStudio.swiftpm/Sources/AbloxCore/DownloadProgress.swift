import Foundation

/// How far one download has got, in bytes.
///
/// The Games tab shows it in megabytes: "0.4 / 1.2 MB" while a game comes
/// down, or just "0.4 MB" when nobody said how big it would be.
public struct DownloadMeter: Equatable, Sendable {
    /// Bytes received so far.
    public var received: Int
    /// How big the whole will be, when that is known.
    public var expected: Int?

    public init(received: Int = 0, expected: Int? = nil) {
        self.received = max(0, received)
        self.expected = expected.flatMap { $0 > 0 ? $0 : nil }
    }

    /// 0…1, or nil when the size is not known.
    public var fraction: Double? {
        guard let expected else { return nil }
        return Swift.min(1, Double(received) / Double(expected))
    }

    /// "0.4 / 1.2 MB", or "0.4 MB".
    public var text: String {
        guard let expected, expected >= received else { return Megabytes.text(received) }
        return Megabytes.text(received, of: expected)
    }
}

/// "Download every game": one game after another, with the megabytes added up.
public struct BulkDownload: Equatable, Sendable {
    /// Games to fetch, and how many are over (fetched or not).
    public var total: Int
    public var done = 0
    public var failed = 0
    /// Every byte received in this run, the game coming down now included.
    public var bytes = 0
    /// The sum of the games' sizes, when the list gave every one.
    public var expectedBytes: Int?
    /// The game coming down now.
    public var current: String?
    public var currentMeter = DownloadMeter()
    public var cancelled = false
    public var finished = false

    public init(total: Int, expectedBytes: Int? = nil) {
        self.total = max(0, total)
        self.expectedBytes = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    /// 0…1: the games finished, and part of the one coming down.
    public var fraction: Double {
        if let expectedBytes { return Swift.min(1, Double(bytes) / Double(expectedBytes)) }
        guard total > 0 else { return 1 }
        let partial = current == nil ? 0 : (currentMeter.fraction ?? 0)
        return Swift.min(1, (Double(done) + partial) / Double(total))
    }

    /// "12 / 65 games · 8.4 / 45.6 MB".
    public var summary: String {
        let size = expectedBytes.map { bytes <= $0 ? Megabytes.text(bytes, of: $0) : Megabytes.text(bytes) } ?? Megabytes.text(bytes)
        return L("{} / {} games · {}", done, total, size)
    }
}

/// Byte counts as the Games tab says them. "MB" is the same in every
/// language the app speaks, and short enough for a game's card.
public enum Megabytes {
    private static let perMB = 1_048_576.0

    /// "0.4 MB", "12.3 MB", "1.2 GB". Anything above nothing is at least 0.1 MB.
    public static func text(_ bytes: Int) -> String {
        if Double(bytes) >= perMB * 1024 { return String(format: "%.1f GB", Double(bytes) / perMB / 1024) }
        return number(bytes) + " MB"
    }

    /// "0.4 / 1.2 MB".
    public static func text(_ bytes: Int, of total: Int) -> String {
        if Double(total) >= perMB * 1024 {
            return String(format: "%.1f / %.1f GB", Double(bytes) / perMB / 1024, Double(total) / perMB / 1024)
        }
        return number(bytes) + " / " + number(total) + " MB"
    }

    /// The megabytes alone, one decimal place.
    public static func number(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0.0" }
        let mb = Double(bytes) / perMB
        return mb < 0.1 ? "0.1" : String(format: "%.1f", mb)
    }
}
