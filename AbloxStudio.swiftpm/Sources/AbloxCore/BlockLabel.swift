import Foundation

/// Words floating over a block, always turned to the camera: a sign's text, a
/// price, a pet's name with its rarity above and what it earns below.
///
/// Optional on `BlockData`, so a world or an update from an iPad that has not
/// updated yet reads the same as before (it shows the block, without words),
/// and the network protocol stays the same.
public struct BlockLabel: Codable, Hashable, Sendable {

    /// One line, in its own colour.
    public struct Line: Codable, Hashable, Sendable {
        public var text: String
        public var color: ColorRGBA

        public init(text: String, color: ColorRGBA = .white) {
            self.text = String(text.prefix(Limits.maximumLineLength))
            self.color = color
        }
    }

    public enum Limits {
        public static let maximumLines = 4
        public static let maximumLineLength = 60
        public static let heights: ClosedRange<Float> = 0...40
        public static let sizes: ClosedRange<Float> = 0.3...4
        public static let ranges: ClosedRange<Float> = 4...250
    }

    public var lines: [Line]
    /// How far above the top of the block, in studs.
    public var height: Float
    /// Times the usual size.
    public var size: Float
    /// Shown up to this far from the camera.
    public var range: Float

    public init(lines: [Line] = [], height: Float = 0.6, size: Float = 1, range: Float = 60) {
        self.lines = Array(lines.prefix(Limits.maximumLines))
        self.height = Self.clamp(height, Limits.heights)
        self.size = Self.clamp(size, Limits.sizes)
        self.range = Self.clamp(range, Limits.ranges)
    }

    /// One line of white text per line of `text`.
    public init(text: String) {
        self.init(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map { Line(text: String($0)) })
    }

    /// Nothing to show.
    public var isEmpty: Bool {
        lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The lines as one text, for reading back in a script.
    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    // A label written by hand (or by an older or newer iPad) is held to the
    // same limits as one made here.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lines = try container.decodeIfPresent([Line].self, forKey: .lines) ?? []
        self.init(lines: lines.map { Line(text: $0.text, color: $0.color) },
                  height: try container.decodeIfPresent(Float.self, forKey: .height) ?? 0.6,
                  size: try container.decodeIfPresent(Float.self, forKey: .size) ?? 1,
                  range: try container.decodeIfPresent(Float.self, forKey: .range) ?? 60)
    }

    private static func clamp(_ value: Float, _ range: ClosedRange<Float>) -> Float {
        value.isFinite ? Swift.min(Swift.max(value, range.lowerBound), range.upperBound) : range.lowerBound
    }
}
