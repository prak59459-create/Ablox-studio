import Foundation

/// A portable linear-agnostic RGBA color with components in `0...1`.
///
/// Stored as four floats rather than a hex string so that colour animations
/// (`EventAction.tint`) can interpolate without repeated parsing, and so the
/// JSON stays human-diffable in saved worlds.
public struct ColorRGBA: Codable, Hashable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`. The leading `#` is
    /// optional. Returns `nil` for anything else.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }

        func component(_ substring: Substring, scale: Float) -> Float {
            Float(UInt8(substring, radix: 16) ?? 0) / scale
        }

        let chars = Array(s)
        switch chars.count {
        case 3, 4:
            // Shorthand: each nibble is doubled, so 0xF -> 0xFF.
            let values = chars.map { Float(UInt8(String($0), radix: 16) ?? 0) / 15 }
            self.init(r: values[0], g: values[1], b: values[2], a: chars.count == 4 ? values[3] : 1)
        case 6, 8:
            let pairs = stride(from: 0, to: chars.count, by: 2).map { i -> Float in
                component(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], scale: 255)
            }
            self.init(r: pairs[0], g: pairs[1], b: pairs[2], a: pairs.count == 4 ? pairs[3] : 1)
        default:
            return nil
        }
    }

    /// Uppercase `#RRGGBB`, or `#RRGGBBAA` when the color is translucent.
    public var hexString: String {
        func byte(_ value: Float) -> Int {
            Int((Swift.max(0, Swift.min(1, value)) * 255).rounded())
        }
        let base = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        return a >= 0.999 ? base : base + String(format: "%02X", byte(a))
    }

    public var isOpaque: Bool { a >= 0.999 }

    public func withAlpha(_ alpha: Float) -> ColorRGBA {
        ColorRGBA(r: r, g: g, b: b, a: alpha)
    }

    public static func lerp(_ from: ColorRGBA, _ to: ColorRGBA, _ t: Float) -> ColorRGBA {
        let clamped = Swift.max(0, Swift.min(1, t))
        // Written out rather than calling the free `lerp(_:_:_:)` in Math.swift.
        // Inside a type that has its own static `lerp`, the free one can only be
        // reached by naming its module — and the module has two names: the app
        // target (`AbloxApp`) on device, `AbloxCore` in the off-device test
        // package. Hard-coding either breaks the other build, and only the iPad
        // can report the one it breaks.
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * clamped }
        return ColorRGBA(
            r: mix(from.r, to.r),
            g: mix(from.g, to.g),
            b: mix(from.b, to.b),
            a: mix(from.a, to.a)
        )
    }

    /// Relative luminance (Rec. 709). The Studio inspector uses this to decide
    /// whether a swatch needs dark or light text on top of it.
    public var luminance: Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - Palette

public extension ColorRGBA {
    static let white = ColorRGBA(r: 1, g: 1, b: 1)
    static let black = ColorRGBA(r: 0, g: 0, b: 0)

    /// The default palette offered by the Studio's colour picker.
    /// Tuned to read well against the dark viewport background.
    static let palette: [ColorRGBA] = [
        ColorRGBA(hex: "#FF5A5F")!, // coral
        ColorRGBA(hex: "#FF9F1C")!, // amber
        ColorRGBA(hex: "#FFD60A")!, // sun
        ColorRGBA(hex: "#4ADE80")!, // mint
        ColorRGBA(hex: "#22D3EE")!, // cyan
        ColorRGBA(hex: "#3B82F6")!, // blue
        ColorRGBA(hex: "#A855F7")!, // violet
        ColorRGBA(hex: "#EC4899")!, // pink
        ColorRGBA(hex: "#F5F5F5")!, // chalk
        ColorRGBA(hex: "#9CA3AF")!, // concrete
        ColorRGBA(hex: "#4B5563")!, // slate
        ColorRGBA(hex: "#1F2937")!  // graphite
    ]

    static let defaultBlock = ColorRGBA(hex: "#9CA3AF")!
    static let defaultGround = ColorRGBA(hex: "#2F4F3E")!
}
