import Foundation

// A block's shape, in a file of its own, split from BlockData.swift: a
// change here rebuilds only the files that use what is here, not every file
// that uses anything that was declared beside it.

/// The primitive a block renders as. Deliberately a small closed set: every
/// case maps to a `MeshResource` generator RealityKit ships with, so worlds
/// never depend on bundled assets and stay portable between iPads.
public enum BlockShape: String, Codable, CaseIterable, Sendable, ComparedByCase {
    case box
    case sphere
    case cylinder
    case cone
    case plane

    public var displayName: String {
        switch self {
        case .box: return L("Box")
        case .sphere: return L("Sphere")
        case .cylinder: return L("Cylinder")
        case .cone: return L("Cone")
        case .plane: return L("Plane")
        }
    }

    /// SF Symbol used in the Explorer tree and the part palette.
    public var symbolName: String {
        switch self {
        case .box: return "cube.fill"
        case .sphere: return "circle.fill"
        case .cylinder: return "cylinder.fill"
        case .cone: return "cone.fill"
        case .plane: return "square.fill"
        }
    }

    /// Local-space bounds for a unit-scaled block of this shape, centred on
    /// the origin. Shared by picking, framing, and the physics collider so all
    /// three agree on how big a block is.
    public var unitBounds: BoundingBox {
        switch self {
        case .box, .sphere, .cylinder, .cone:
            return BoundingBox(center: .zero, size: Vec3(1, 1, 1))
        case .plane:
            // A plane is flat in Y but still needs a pickable thickness.
            return BoundingBox(center: .zero, size: Vec3(1, 0.01, 1))
        }
    }
}
