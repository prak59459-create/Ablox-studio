import Foundation

// What a block is made of, in a file of its own, split from BlockData.swift:
// a change here rebuilds only the files that use what is here, not every
// file that uses anything that was declared beside it.

/// A surface preset. Maps to `SimpleMaterial`/`UnlitMaterial` parameters at
/// render time — see `BlockEntityFactory`.
public enum MaterialKind: String, Codable, CaseIterable, Sendable, ComparedByCase {
    case plastic
    case metal
    case glass
    case neon
    case matte
    // Natural surfaces, drawn with a pattern made on the iPad (schema 2).
    case wood
    case stone
    case brick
    case grass
    case sand
    case ice
    /// Players swim in it rather than stand on it.
    case water

    public var displayName: String {
        switch self {
        case .plastic: return L("Plastic")
        case .metal: return L("Metal")
        case .glass: return L("Glass")
        case .neon: return L("Neon")
        case .matte: return L("Matte")
        case .wood: return L("Wood")
        case .stone: return L("Stone")
        case .brick: return L("Brick")
        case .grass: return L("Grass")
        case .sand: return L("Sand")
        case .ice: return L("Ice")
        case .water: return L("Water")
        }
    }

    public var roughness: Float {
        switch self {
        case .plastic: return 0.45
        case .metal: return 0.15
        case .glass: return 0.05
        case .neon: return 1.0
        case .matte, .stone, .brick, .sand: return 0.95
        case .wood, .grass: return 0.85
        case .ice: return 0.1
        case .water: return 0.05
        }
    }

    public var isMetallic: Bool { self == .metal }

    /// Neon blocks render unlit so they read as emissive without needing a
    /// light probe, and glass needs alpha blending.
    public var isUnlit: Bool { self == .neon }

    /// Multiplier applied to the block's own alpha.
    public var alphaScale: Float {
        switch self {
        case .glass: return 0.35
        case .water: return 0.6
        case .ice: return 0.8
        default: return 1.0
        }
    }

    /// Players swim in it; it holds nobody up.
    public var isLiquid: Bool { self == .water }

    /// Newer than the first world format: a world using one needs schema 2.
    public var needsSchema2: Bool {
        switch self {
        case .plastic, .metal, .glass, .neon, .matte: return false
        case .wood, .stone, .brick, .grass, .sand, .ice, .water: return true
        }
    }

    /// The pattern drawn on the surface.
    public var pattern: SurfacePattern {
        switch self {
        case .plastic, .metal, .glass, .neon, .matte: return .none
        case .wood: return .grain
        case .stone: return .speckle
        case .brick: return .bricks
        case .grass: return .blades
        case .sand: return .speckle
        case .ice: return .cracks
        case .water: return .ripples
        }
    }
}

/// Patterns made on the iPad for the natural materials, so a world carries
/// no image files.
public enum SurfacePattern: String, Sendable {
    case none, grain, speckle, bricks, blades, cracks, ripples
}
