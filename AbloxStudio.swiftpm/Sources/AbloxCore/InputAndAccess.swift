import Foundation

// Playing without the touch screen — a game controller, a keyboard, a mouse —
// and playing with eyes that see colour differently or not at all.

// MARK: - Sticks and keys

public enum StickShaping {

    /// Below this, a stick is treated as centred: worn controllers rest a
    /// little off the middle and would otherwise walk on their own.
    public static let deadZone: Float = 0.15

    /// A stick's position with the dead zone taken out and the rest spread
    /// back over the whole range, so just past the dead zone is slow and all
    /// the way is full speed. Never longer than 1.
    public static func shaped(x: Float, y: Float, deadZone: Float = StickShaping.deadZone) -> (x: Float, y: Float) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let length = (x * x + y * y).squareRoot()
        guard length > deadZone else { return (0, 0) }
        let scaled = Swift.min(1, (length - deadZone) / (1 - deadZone))
        return (x / length * scaled, y / length * scaled)
    }

    /// How far a look stick turns the camera this frame, in degrees: a
    /// gentle curve so small movements aim finely and full tilt turns fast.
    public static func lookDegrees(_ value: Float, seconds: Float, sensitivity: Float, fullSpeed: Float = 200) -> Float {
        guard value.isFinite, seconds.isFinite, sensitivity.isFinite else { return 0 }
        let curved = value * Swift.abs(value)
        return curved * fullSpeed * Swift.max(0.1, sensitivity) * Swift.min(seconds, 0.1)
    }
}

public enum KeyMovement {

    /// The stick that W, A, S and D (or the arrow keys) make: `x` right, `z`
    /// forward, a diagonal no faster than straight on.
    public static func stick(forward: Bool, back: Bool, left: Bool, right: Bool) -> Vec3 {
        let x: Float = (right ? 1 : 0) - (left ? 1 : 0)
        let z: Float = (forward ? 1 : 0) - (back ? 1 : 0)
        let length = (x * x + z * z).squareRoot()
        guard length > 0 else { return .zero }
        return Vec3(x / length, 0, z / length)
    }
}

// MARK: - Colour vision

/// Help for players who see colour differently: the game picture shifted so
/// colours that look alike come apart, and (separately) dangers and goals
/// marked with patterns so nothing depends on colour alone.
public enum ColourVision: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// Deuteranopia and deuteranomaly: the most common.
    case redGreen
    /// Protanopia: reds also look dark.
    case red
    /// Tritanopia.
    case blueYellow
    /// Everything in shades of grey, with more contrast.
    case greyscale

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return L("Off")
        case .redGreen: return L("Red and green look alike")
        case .red: return L("Reds look dark")
        case .blueYellow: return L("Blue and yellow look alike")
        case .greyscale: return L("Shades of grey")
        }
    }

    /// Three rows of three, applied to red, green and blue: what the game's
    /// picture is multiplied by. `nil` for off.
    ///
    /// Daltonising: work out what the player would see (`simulation`), take
    /// the difference from the real colour — the part they miss — and add it
    /// back into channels they can see. All of it is linear, so the whole
    /// correction is one matrix: I + E(I − S).
    public var matrix: [Float]? {
        let simulation: [Float]
        switch self {
        case .off: return nil
        case .greyscale:
            // Luminance, stretched a little for contrast.
            let r: Float = 0.2126 * 1.1, g: Float = 0.7152 * 1.1, b: Float = 0.0722 * 1.1
            return [r, g, b, r, g, b, r, g, b]
        case .redGreen:
            simulation = [0.625, 0.375, 0, 0.7, 0.3, 0, 0, 0.3, 0.7]
        case .red:
            simulation = [0.567, 0.433, 0, 0.558, 0.442, 0, 0, 0.242, 0.758]
        case .blueYellow:
            simulation = [0.95, 0.05, 0, 0, 0.433, 0.567, 0, 0.475, 0.525]
        }
        // Where the missed part goes: red's into green and blue.
        let shift: [Float] = [0, 0, 0, 0.7, 1, 0, 0.7, 0, 1]
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let missed = zip(identity, simulation).map { $0 - $1 }
        let added = Self.multiply(shift, missed)
        return zip(identity, added).map { $0 + $1 }
    }

    /// A colour as this correction shows it (for tests and previews).
    public func corrected(_ color: ColorRGBA) -> ColorRGBA {
        guard let m = matrix else { return color }
        func clamp(_ v: Float) -> Float { Swift.max(0, Swift.min(1, v)) }
        return ColorRGBA(r: clamp(m[0] * color.r + m[1] * color.g + m[2] * color.b),
                         g: clamp(m[3] * color.r + m[4] * color.g + m[5] * color.b),
                         b: clamp(m[6] * color.r + m[7] * color.g + m[8] * color.b),
                         a: color.a)
    }

    private static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum: Float = 0
                for k in 0..<3 { sum += a[row * 3 + k] * b[k * 3 + column] }
                result[row * 3 + column] = sum
            }
        }
        return result
    }
}

/// Patterns that say what a part does without its colour.
public enum MeaningMark: String, Sendable {
    /// Diagonal stripes: this hurts.
    case danger
    /// Checks, like a finish flag: the goal.
    case goal

    public static func mark(for behavior: BlockBehavior) -> MeaningMark? {
        switch behavior {
        case .hazard: return .danger
        case .goal: return .goal
        default: return nil
        }
    }
}

// MARK: - Colours, in words

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
