import Foundation

// Particles, in a file of its own, split from WorldFeatures.swift: a change
// here rebuilds only the files that use what is here, not every file that
// uses anything that was declared beside it.

public enum ParticleKind: String, Codable, CaseIterable, Sendable, ComparedByCase {
    case fire, smoke, sparkles, confetti, rain, snow, bubbles, hearts, stars, leaves, magic, dust

    public var displayName: String {
        switch self {
        case .fire: return L("Fire")
        case .smoke: return L("Smoke")
        case .sparkles: return L("Sparkles")
        case .confetti: return L("Confetti")
        case .rain: return L("Rain")
        case .snow: return L("Snow")
        case .bubbles: return L("Bubbles")
        case .hearts: return L("Hearts")
        case .stars: return L("Stars")
        case .leaves: return L("Leaves")
        case .magic: return L("Magic")
        case .dust: return L("Dust")
        }
    }

    /// How the bits look and move.
    public var spec: ParticleSpec {
        func hex(_ value: String) -> ColorRGBA { ColorRGBA(hex: value) ?? ColorRGBA(r: 1, g: 1, b: 1) }
        switch self {
        case .fire:
            return ParticleSpec(colors: [hex("#FDE047"), hex("#FB923C"), hex("#EF4444")], rate: 40, lifetime: 0.4...0.9,
                                speed: 1.2, spread: 25, upward: 2.2, gravity: 1.5, size: 0.22, shrinks: true, glows: true)
        case .smoke:
            return ParticleSpec(colors: [hex("#9CA3AF"), hex("#6B7280")], rate: 14, lifetime: 1.4...2.6,
                                speed: 0.5, spread: 30, upward: 1.1, gravity: 0.3, size: 0.45, shrinks: false, glows: false)
        case .sparkles:
            return ParticleSpec(colors: [hex("#FEF08A"), hex("#FFFFFF"), hex("#A5F3FC")], rate: 24, lifetime: 0.5...1.1,
                                speed: 1.6, spread: 180, upward: 0.4, gravity: -0.5, size: 0.1, shrinks: true, glows: true)
        case .confetti:
            return ParticleSpec(colors: [hex("#F43F5E"), hex("#22D3EE"), hex("#FACC15"), hex("#A855F7"), hex("#4ADE80")],
                                rate: 60, lifetime: 1.6...2.6, speed: 5, spread: 55, upward: 5, gravity: -7, size: 0.12,
                                shrinks: false, glows: false)
        case .rain:
            return ParticleSpec(colors: [hex("#93C5FD")], rate: 220, lifetime: 0.7...1.0,
                                speed: 0.2, spread: 5, upward: -16, gravity: -4, size: 0.05, shrinks: false, glows: false)
        case .snow:
            return ParticleSpec(colors: [hex("#FFFFFF"), hex("#E0F2FE")], rate: 90, lifetime: 3...5,
                                speed: 0.5, spread: 180, upward: -1.3, gravity: 0, size: 0.1, shrinks: false, glows: true)
        case .bubbles:
            return ParticleSpec(colors: [hex("#BAE6FD"), hex("#E0F2FE")], rate: 12, lifetime: 1.5...3,
                                speed: 0.4, spread: 40, upward: 1.2, gravity: 0.2, size: 0.18, shrinks: false, glows: false)
        case .hearts:
            return ParticleSpec(colors: [hex("#F472B6"), hex("#FB7185")], rate: 10, lifetime: 1.2...2,
                                speed: 0.6, spread: 50, upward: 1.4, gravity: 0.2, size: 0.2, shrinks: true, glows: true)
        case .stars:
            return ParticleSpec(colors: [hex("#FDE047"), hex("#FFFFFF")], rate: 18, lifetime: 0.8...1.5,
                                speed: 2.2, spread: 180, upward: 1, gravity: -2, size: 0.16, shrinks: true, glows: true)
        case .leaves:
            return ParticleSpec(colors: [hex("#84CC16"), hex("#F59E0B"), hex("#EA580C")], rate: 8, lifetime: 3...5,
                                speed: 0.8, spread: 180, upward: -0.9, gravity: 0, size: 0.18, shrinks: false, glows: false)
        case .magic:
            return ParticleSpec(colors: [hex("#C084FC"), hex("#818CF8"), hex("#F0ABFC")], rate: 30, lifetime: 0.7...1.4,
                                speed: 1, spread: 180, upward: 1.2, gravity: 0.5, size: 0.12, shrinks: true, glows: true)
        case .dust:
            return ParticleSpec(colors: [hex("#D6D3D1"), hex("#A8A29E")], rate: 16, lifetime: 0.6...1.2,
                                speed: 1.4, spread: 70, upward: 0.4, gravity: -1, size: 0.14, shrinks: true, glows: false)
        }
    }
}

public struct ParticleSpec: Hashable, Sendable {
    public var colors: [ColorRGBA]
    /// Bits a second from a block that keeps giving them off.
    public var rate: Float
    public var lifetime: ClosedRange<Float>
    /// How fast they fly off, and in how wide a cone (degrees; 180 is all
    /// ways).
    public var speed: Float
    public var spread: Float
    /// Straight up at the start (negative falls).
    public var upward: Float
    /// Added to the upward speed every second (negative pulls down).
    public var gravity: Float
    public var size: Float
    public var shrinks: Bool
    /// Drawn as light, not lit.
    public var glows: Bool
}

/// Some bits all at once, or for a few seconds, at a place.
public struct ParticleBurst: Codable, Hashable, Sendable {
    public static let maximumAmount = 200
    public static let maximumSeconds: Double = 30

    public var kind: ParticleKind
    public var position: Vec3
    /// How many at once (a puff), or a second for `seconds`.
    public var amount: Int
    /// 0 for one puff.
    public var seconds: Double
    public var color: ColorRGBA?

    public init(kind: ParticleKind, position: Vec3, amount: Int = 30, seconds: Double = 0, color: ColorRGBA? = nil) {
        self.kind = kind
        self.position = position
        self.amount = Swift.max(1, Swift.min(Self.maximumAmount, amount))
        self.seconds = Swift.max(0, Swift.min(Self.maximumSeconds, seconds.isFinite ? seconds : 0))
        self.color = color
    }
}
