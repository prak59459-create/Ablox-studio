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
        ColorRGBA(hex: "#1F2937")!, // graphite
        // Added later: at the end, so a colour's place in the list (which
        // look codes and saved choices use) never moves.
        ColorRGBA(hex: "#A3E635")!, // lime
        ColorRGBA(hex: "#14B8A6")!, // teal
        ColorRGBA(hex: "#C4B5FD")!, // lavender
        ColorRGBA(hex: "#FDBA74")!, // peach
        ColorRGBA(hex: "#7C4A2D")!  // chocolate
    ]

    /// Red to violet, for rainbow trails and auras.
    static let rainbow: [ColorRGBA] = ["#EF4444", "#F97316", "#FACC15", "#4ADE80", "#22D3EE", "#3B82F6", "#A855F7"]
        .compactMap { ColorRGBA(hex: $0) }

    /// The palette as it first was, for anything that must look the same on
    /// every version (a generated avatar).
    static var originalPalette: ArraySlice<ColorRGBA> { palette.prefix(12) }

    static let defaultBlock = ColorRGBA(hex: "#9CA3AF")!
    static let defaultGround = ColorRGBA(hex: "#2F4F3E")!
}

// MARK: - Colours in words, mixed and kept in range
//
// What the app adds to colours is here, beside the type, not in the files
// that use it: an extension of a type this many files use makes its file a
// dependency of all of them, so changing a feature file would rebuild them
// all (AbloxCore/Comparisons.swift says why).
public extension ColorRGBA {

    /// A plain name for the colour ("dark blue", "pink"), for VoiceOver.
    var spokenName: String {
        let r = Swift.max(0, Swift.min(1, self.r.isFinite ? self.r : 0))
        let g = Swift.max(0, Swift.min(1, self.g.isFinite ? self.g : 0))
        let b = Swift.max(0, Swift.min(1, self.b.isFinite ? self.b : 0))
        let high = Swift.max(r, g, b), low = Swift.min(r, g, b)
        let lightness = (high + low) / 2
        let chroma = high - low

        if chroma < 0.12 {
            if lightness > 0.88 { return L("white") }
            if lightness < 0.14 { return L("black") }
            return lightness > 0.6 ? L("light grey") : lightness < 0.35 ? L("dark grey") : L("grey")
        }

        var hue: Float
        if high == r {
            hue = (g - b) / chroma
        } else if high == g {
            hue = (b - r) / chroma + 2
        } else {
            hue = (r - g) / chroma + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }

        let base: String
        switch hue {
        case ..<15, 345...: base = lightness > 0.7 ? L("pink") : L("red")
        case ..<40: base = lightness < 0.4 ? L("brown") : L("orange")
        case ..<70: base = lightness < 0.35 ? L("olive") : L("yellow")
        case ..<160: base = L("green")
        case ..<195: base = L("turquoise")
        case ..<250: base = L("blue")
        case ..<290: base = L("purple")
        default: base = L("pink")
        }
        if lightness > 0.75, base != L("pink") { return L("light {}", base) }
        if high < 0.5, base != L("brown"), base != L("olive") { return L("dark {}", base) }
        return base
    }
}

extension ColorRGBA {
    /// Every channel a real number from 0 to 1.
    var clamped: ColorRGBA {
        func unit(_ v: Float) -> Float { v.isFinite ? Swift.min(1, Swift.max(0, v)) : 0 }
        return ColorRGBA(r: unit(r), g: unit(g), b: unit(b), a: unit(a))
    }
}

public extension ColorRGBA {
    /// Part of the way from this colour to `other`.
    func mixed(with other: ColorRGBA, amount: Float) -> ColorRGBA {
        let t = Swift.max(0, Swift.min(1, amount))
        return ColorRGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }
}
