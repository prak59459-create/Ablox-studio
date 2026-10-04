import Foundation

// The light a block gives off, in a file of its own, split from
// BlockData.swift: a change here rebuilds only the files that use what is
// here, not every file that uses anything that was declared beside it.

/// Light a block gives off: all round (a lamp) or in a cone (a spotlight,
/// pointing the way the block's top faces).
public struct BlockLight: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, ComparedByCase {
        case point, spot

        public var displayName: String {
            switch self {
            case .point: return L("Lamp")
            case .spot: return L("Spotlight")
            }
        }
    }

    public var kind: Kind
    public var color: ColorRGBA
    /// 0 to 1: how bright.
    public var intensity: Float
    /// Metres it reaches.
    public var range: Float

    public init(kind: Kind = .point, color: ColorRGBA = ColorRGBA(r: 1, g: 0.9, b: 0.7), intensity: Float = 0.6, range: Float = 10) {
        self.kind = kind
        self.color = color
        self.intensity = Swift.max(0, Swift.min(1, intensity.isFinite ? intensity : 0.6))
        self.range = Swift.max(1, Swift.min(50, range.isFinite ? range : 10))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .point,
                  color: (try? c.decodeIfPresent(ColorRGBA.self, forKey: .color)) ?? ColorRGBA(r: 1, g: 0.9, b: 0.7),
                  intensity: (try? c.decodeIfPresent(Float.self, forKey: .intensity)) ?? 0.6,
                  range: (try? c.decodeIfPresent(Float.self, forKey: .range)) ?? 10)
    }

    /// Most lamps lit at once: each is drawn with every part it reaches.
    public static let maximumLit = 8
}
