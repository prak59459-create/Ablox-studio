import Foundation

// MARK: - Shape

/// The primitive a block renders as. Deliberately a small closed set: every
/// case maps to a `MeshResource` generator RealityKit ships with, so worlds
/// never depend on bundled assets and stay portable between iPads.
public enum BlockShape: String, Codable, CaseIterable, Sendable {
    case box
    case sphere
    case cylinder
    case cone
    case plane

    public var displayName: String {
        switch self {
        case .box: return "Box"
        case .sphere: return "Sphere"
        case .cylinder: return "Cylinder"
        case .cone: return "Cone"
        case .plane: return "Plane"
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

// MARK: - Material

/// A surface preset. Maps to `SimpleMaterial`/`UnlitMaterial` parameters at
/// render time — see `BlockEntityFactory`.
public enum MaterialKind: String, Codable, CaseIterable, Sendable {
    case plastic
    case metal
    case glass
    case neon
    case matte

    public var displayName: String {
        switch self {
        case .plastic: return "Plastic"
        case .metal: return "Metal"
        case .glass: return "Glass"
        case .neon: return "Neon"
        case .matte: return "Matte"
        }
    }

    public var roughness: Float {
        switch self {
        case .plastic: return 0.45
        case .metal: return 0.15
        case .glass: return 0.05
        case .neon: return 1.0
        case .matte: return 0.95
        }
    }

    public var isMetallic: Bool { self == .metal }

    /// Neon blocks render unlit so they read as emissive without needing a
    /// light probe, and glass needs alpha blending.
    public var isUnlit: Bool { self == .neon }

    /// Multiplier applied to the block's own alpha.
    public var alphaScale: Float { self == .glass ? 0.35 : 1.0 }
}

// MARK: - Behavior

/// Gameplay meaning attached to a block. This is the bridge between the
/// Studio's authoring model and the runtime: `EventRuntime` reads it to decide
/// what a touch actually does, without needing a rule for every common case.
public enum BlockBehavior: String, Codable, CaseIterable, Sendable {
    /// Inert scenery.
    case none
    /// Players spawn (and respawn) at this block's top face.
    case spawn
    /// Touching it updates the player's respawn point.
    case checkpoint
    /// Touching it sends the player back to their respawn point.
    case hazard
    /// Touching it awards `scoreValue` and hides the block for that player.
    case collectible
    /// Touching it ends the round for that player.
    case goal
    /// Inert by itself — exists so `EventRule`s can hang off it.
    case trigger

    // MARK: Gimmicks
    //
    // The no-code vocabulary: an author picks one of these in the Inspector
    // and the block does something, with no rule to write. Each is tuned by
    // `BlockData.gimmick`.

    /// Launches the player upward. A trampoline.
    case bounce
    /// Fades out shortly after being stepped on, then returns. The classic
    /// disappearing-platform trap.
    case disappear
    /// Moves the player to `gimmick.teleportTargetID`. A warp pad.
    case teleport

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .spawn: return "Spawn Point"
        case .checkpoint: return "Checkpoint"
        case .hazard: return "Hazard"
        case .collectible: return "Collectible"
        case .goal: return "Goal"
        case .trigger: return "Trigger"
        case .bounce: return "Bouncy"
        case .disappear: return "Disappearing"
        case .teleport: return "Teleporter"
        }
    }

    public var symbolName: String {
        switch self {
        case .none: return "circle.dashed"
        case .spawn: return "figure.stand"
        case .checkpoint: return "flag.fill"
        case .hazard: return "exclamationmark.triangle.fill"
        case .collectible: return "star.fill"
        case .goal: return "flag.checkered"
        case .trigger: return "bolt.fill"
        case .bounce: return "arrow.up.circle.fill"
        case .disappear: return "square.dashed"
        case .teleport: return "sparkles"
        }
    }

    /// Whether the runtime must be told when a player touches this block.
    public var needsTouchDetection: Bool {
        switch self {
        case .none, .spawn: return false
        case .checkpoint, .hazard, .collectible, .goal, .trigger: return true
        // Every gimmick fires on contact, so the runtime has to be told.
        case .bounce, .disappear, .teleport: return true
        }
    }

    /// Whether this behaviour is one of the no-code gimmicks, which share the
    /// `BlockData.gimmick` tuning and a per-block cooldown.
    public var isGimmick: Bool {
        switch self {
        case .bounce, .disappear, .teleport: return true
        case .none, .spawn, .checkpoint, .hazard, .collectible, .goal, .trigger: return false
        }
    }
}

// MARK: - Gimmick tuning

/// Parameters for the no-code gimmick behaviours.
///
/// Gathered into one struct rather than five loose fields on `BlockData`,
/// because they are only meaningful together and only when `behavior` is a
/// gimmick. That keeps `BlockData` readable and keeps a world file from
/// carrying five nulls on every inert block.
public struct GimmickSettings: Codable, Hashable, Sendable {

    /// Upward speed, in m/s, imparted by a `.bounce` block.
    ///
    /// Default is comfortably above `MovementConfig.jumpSpeed`, so a
    /// trampoline always feels like more than a jump.
    public var bounceSpeed: Float

    /// Seconds between a `.disappear` block being stepped on and it going.
    /// The grace period is the whole point — zero would be an instant
    /// trapdoor, which reads as a bug rather than a trap.
    public var disappearDelay: Double

    /// Seconds a `.disappear` block stays gone before returning.
    public var respawnDelay: Double

    /// Where a `.teleport` block sends the player. The player arrives above
    /// this block's top face. A nil or dangling target makes the block inert
    /// rather than dropping the player through the world.
    public var teleportTargetID: UUID?

    /// Minimum seconds between firings of this specific block.
    ///
    /// Without it a gimmick re-triggers on every contact report while the
    /// player stands on it — a bounce pad would fire dozens of times a second
    /// and fling the player into orbit.
    public var cooldown: Double

    public init(
        bounceSpeed: Float = 14,
        disappearDelay: Double = 0.3,
        respawnDelay: Double = 3.0,
        teleportTargetID: UUID? = nil,
        cooldown: Double = 1.5
    ) {
        self.bounceSpeed = bounceSpeed
        self.disappearDelay = disappearDelay
        self.respawnDelay = respawnDelay
        self.teleportTargetID = teleportTargetID
        self.cooldown = cooldown
    }

    public static let `default` = GimmickSettings()
}

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
        gimmick: GimmickSettings = .default
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
            case .block: return "Block"
            case .platform: return "Platform"
            case .pillar: return "Pillar"
            case .ramp: return "Ramp"
            case .orb: return "Orb"
            case .hazard: return "Hazard"
            case .checkpoint: return "Checkpoint"
            case .goal: return "Goal"
            case .spawn: return "Spawn"
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
    }
}
