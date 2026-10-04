import Foundation

// MARK: - BlockData

/// One authored part in a world.
///
/// Blocks form a tree via `parentID`: `transform` is always **local to the
/// parent**, matching RealityKit's entity hierarchy so the renderer can attach
/// children directly without recomputing anything. Use
/// `WorldDocument.worldTransform(of:)` when world space is what you need.
public struct BlockData: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var shape: BlockShape

    /// Local transform, relative to `parentID` (or the world when nil).
    public var transform: Transform3D

    public var color: ColorRGBA
    public var material: MaterialKind

    /// Anchored blocks are immovable: gravity and collisions never displace
    /// them. Unanchored blocks become dynamic rigid bodies in Play mode.
    public var isAnchored: Bool

    /// When false the block is visual only — players walk straight through it.
    public var hasCollision: Bool

    public var isVisible: Bool

    public var behavior: BlockBehavior

    /// Points awarded by `.collectible`, or deducted by `.hazard`.
    public var scoreValue: Int

    /// Parent in the Explorer tree. `nil` means top level.
    public var parentID: UUID?

    /// Free-form labels. `EventTrigger.tagTouched` matches on these, which
    /// lets one rule cover a whole group of blocks.
    public var tags: [String]

    /// Tuning for `.bounce`, `.disappear` and `.teleport`. Ignored by every
    /// other behaviour.
    public var gimmick: GimmickSettings

    /// Bits it keeps giving off: fire, smoke, sparkles… (schema 2).
    public var particles: ParticleKind?
    /// A picture on it, from `WorldDocument.images` (schema 2).
    public var imageID: UUID?
    /// A lamp or a spotlight in it. An older iPad shows the block, unlit.
    public var light: BlockLight?
    /// Words floating over it (`BlockLabel`). An older iPad shows the block
    /// without them.
    public var label: BlockLabel?
    /// Moving by itself on every iPad (`BlockAnimation`). An older iPad shows
    /// the block still.
    public var animation: BlockAnimation?
    /// Studio's layer for it (nil: the main one). Only the editor reads it.
    public var layer: String?
    /// Written only when locked, so a world's file does not grow a flag on
    /// every block.
    private var lockedFlag: Bool?

    /// Locked in Studio: not picked or moved by accident. Games ignore it.
    public var isLocked: Bool {
        get { lockedFlag ?? false }
        set { lockedFlag = newValue ? true : nil }
    }

    public init(
        id: UUID = UUID(),
        name: String = "Part",
        shape: BlockShape = .box,
        transform: Transform3D = .identity,
        color: ColorRGBA = .defaultBlock,
        material: MaterialKind = .plastic,
        isAnchored: Bool = true,
        hasCollision: Bool = true,
        isVisible: Bool = true,
        behavior: BlockBehavior = .none,
        scoreValue: Int = 0,
        parentID: UUID? = nil,
        tags: [String] = [],
        gimmick: GimmickSettings = .default,
        particles: ParticleKind? = nil,
        imageID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.shape = shape
        self.transform = transform
        self.color = color
        self.material = material
        self.isAnchored = isAnchored
        self.hasCollision = hasCollision
        self.isVisible = isVisible
        self.behavior = behavior
        self.scoreValue = scoreValue
        self.parentID = parentID
        self.tags = tags
        self.gimmick = gimmick
        self.particles = particles
        self.imageID = imageID
    }

    /// Holds players up and stops them: visible, colliding, and not water.
    public var isSolidForPlayers: Bool {
        isVisible && hasCollision && !material.isLiquid
    }

    /// Uses something the first world format did not have.
    public var needsSchema2: Bool {
        material.needsSchema2 || behavior.needsSchema2 || particles != nil || imageID != nil
    }

    // Convenience accessors so call sites read as `block.position` rather than
    // `block.transform.position`.
    public var position: Vec3 {
        get { transform.position }
        set { transform.position = newValue }
    }

    public var rotation: Quat {
        get { transform.rotation }
        set { transform.rotation = newValue }
    }

    public var scale: Vec3 {
        get { transform.scale }
        set { transform.scale = newValue }
    }

    /// Euler angles in degrees, as shown in the Inspector's rotation fields.
    public var rotationDegrees: Vec3 {
        get { transform.rotation.eulerDegrees }
        set { transform.rotation = Quat.euler(degrees: newValue) }
    }

    /// Local-space bounds including this block's own scale, but not its
    /// parents'.
    public var localBounds: BoundingBox {
        let unit = shape.unitBounds
        return BoundingBox(center: transform.position, size: unit.size * transform.scale)
    }

    public func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

// MARK: - Decoding tolerance

public extension BlockData {
    /// Worlds authored by an older build may be missing newer fields. Rather
    /// than failing the whole document, decode leniently and fall back to the
    /// same defaults `init` uses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Part"
        shape = try c.decodeIfPresent(BlockShape.self, forKey: .shape) ?? .box
        transform = try c.decodeIfPresent(Transform3D.self, forKey: .transform) ?? .identity
        color = try c.decodeIfPresent(ColorRGBA.self, forKey: .color) ?? .defaultBlock
        material = try c.decodeIfPresent(MaterialKind.self, forKey: .material) ?? .plastic
        isAnchored = try c.decodeIfPresent(Bool.self, forKey: .isAnchored) ?? true
        hasCollision = try c.decodeIfPresent(Bool.self, forKey: .hasCollision) ?? true
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        behavior = try c.decodeIfPresent(BlockBehavior.self, forKey: .behavior) ?? .none
        scoreValue = try c.decodeIfPresent(Int.self, forKey: .scoreValue) ?? 0
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        gimmick = try c.decodeIfPresent(GimmickSettings.self, forKey: .gimmick) ?? .default
        particles = try? c.decodeIfPresent(ParticleKind.self, forKey: .particles)
        imageID = try? c.decodeIfPresent(UUID.self, forKey: .imageID)
        light = try? c.decodeIfPresent(BlockLight.self, forKey: .light)
        label = try? c.decodeIfPresent(BlockLabel.self, forKey: .label)
        animation = try? c.decodeIfPresent(BlockAnimation.self, forKey: .animation)
        layer = (try? c.decodeIfPresent(String.self, forKey: .layer)).flatMap { $0.map { String($0.prefix(40)) } }
        lockedFlag = (try? c.decodeIfPresent(Bool.self, forKey: .lockedFlag)) ?? nil
    }
}

// MARK: - Presets

public extension BlockData {
    /// The parts offered in the Studio's "+" palette.
    static func preset(_ kind: PresetKind, at position: Vec3) -> BlockData {
        switch kind {
        case .block:
            return BlockData(name: "Block", shape: .box, transform: Transform3D(position: position, scale: Vec3(2, 1, 2)))
        case .pillar:
            return BlockData(name: "Pillar", shape: .cylinder, transform: Transform3D(position: position, scale: Vec3(0.6, 4, 0.6)), color: ColorRGBA(hex: "#F5F5F5")!)
        case .ramp:
            return BlockData(
                name: "Ramp",
                shape: .box,
                transform: Transform3D(position: position, rotation: Quat.euler(degrees: Vec3(-25, 0, 0)), scale: Vec3(2, 0.3, 5))
            )
        case .platform:
            return BlockData(name: "Platform", shape: .box, transform: Transform3D(position: position, scale: Vec3(6, 0.5, 6)))
        case .orb:
            return BlockData(
                name: "Orb",
                shape: .sphere,
                transform: Transform3D(position: position, scale: Vec3(repeating: 0.8)),
                color: ColorRGBA(hex: "#FFD60A")!,
                material: .neon,
                hasCollision: true,
                behavior: .collectible,
                scoreValue: 10
            )
        case .hazard:
            return BlockData(
                name: "Lava",
                shape: .box,
                transform: Transform3D(position: position, scale: Vec3(4, 0.4, 4)),
                color: ColorRGBA(hex: "#FF5A5F")!,
                material: .neon,
                behavior: .hazard
            )
        case .checkpoint:
            return BlockData(
                name: "Checkpoint",
                shape: .cylinder,
                transform: Transform3D(position: position, scale: Vec3(1.4, 0.2, 1.4)),
                color: ColorRGBA(hex: "#4ADE80")!,
                material: .neon,
                behavior: .checkpoint
            )
        case .goal:
            return BlockData(
                name: "Goal",
                shape: .box,
                transform: Transform3D(position: position, scale: Vec3(3, 3, 0.4)),
                color: ColorRGBA(hex: "#A855F7")!,
                material: .glass,
                behavior: .goal
            )
        case .spawn:
            return BlockData(
                name: "Spawn",
                shape: .cylinder,
                transform: Transform3D(position: position, scale: Vec3(2, 0.2, 2)),
                color: ColorRGBA(hex: "#22D3EE")!,
                material: .neon,
                behavior: .spawn
            )
        }
    }

    enum PresetKind: String, CaseIterable, Sendable, Identifiable {
        case block, platform, pillar, ramp, orb, hazard, checkpoint, goal, spawn

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .block: return L("Block")
            case .platform: return L("Platform")
            case .pillar: return L("Pillar")
            case .ramp: return L("Ramp")
            case .orb: return L("Orb")
            case .hazard: return L("Hazard")
            case .checkpoint: return L("Checkpoint")
            case .goal: return L("Goal")
            case .spawn: return L("Spawn")
            }
        }

        public var symbolName: String {
            switch self {
            case .block: return "cube.fill"
            case .platform: return "rectangle.fill"
            case .pillar: return "cylinder.fill"
            case .ramp: return "triangle.fill"
            case .orb: return "circle.fill"
            case .hazard: return "flame.fill"
            case .checkpoint: return "flag.fill"
            case .goal: return "flag.checkered"
            case .spawn: return "figure.stand"
            }
        }

        /// What tapping this in the palette actually drops into the world.
        ///
        /// Read by Studio's map-making guide. Deliberately describes the part
        /// that `preset(_:at:)` builds — size, colour and behaviour — rather
        /// than what the name suggests, so the guide cannot promise something
        /// the palette does not produce.
        public var guidance: String {
            switch self {
            case .block: return L("A plain 2×1×2 box. The everyday building material.")
            case .platform: return L("A wide, thin 6×0.5×6 slab. Floors and floating islands.")
            case .pillar: return L("A tall thin cylinder, 4 high. Posts, columns, poles.")
            case .ramp: return L("A long box already tilted 25°, so players can walk up it.")
            case .orb: return L("A glowing yellow sphere worth 10 points, collectible once per player.")
            case .hazard: return L("A flat slab of lava. Touching it sends players back to their checkpoint.")
            case .checkpoint: return L("A green pad that saves where a player respawns.")
            case .goal: return L("A purple glass gate. Touching it ends the round.")
            case .spawn: return L("A cyan pad players start on. Every world needs at least one.")
            }
        }
    }
}
