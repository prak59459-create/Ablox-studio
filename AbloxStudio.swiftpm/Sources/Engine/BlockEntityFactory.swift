import Foundation
import RealityKit
import simd

/// Marks a RealityKit entity as the rendering of a particular `BlockData`,
/// so a hit-test result can be mapped back to the authored block.
public struct BlockComponent: Component {
    public var blockID: UUID
    public var behavior: BlockBehavior

    public init(blockID: UUID, behavior: BlockBehavior) {
        self.blockID = blockID
        self.behavior = behavior
    }
}

/// Builds and updates RealityKit entities from `BlockData`.
///
/// Meshes are cached per shape: a world with two hundred boxes should allocate
/// one box mesh, not two hundred. Materials are not cached, because each block
/// carries its own colour.
public enum BlockEntityFactory {

    // MARK: Mesh cache

    private struct MeshKey: Hashable {
        var shape: BlockShape
        var smooth: Bool
        var segments: Int
        var rings: Int
    }

    private static var meshCache: [MeshKey: MeshResource] = [:]
    private static let cacheLock = NSLock()

    /// A unit-sized mesh for the shape, scaled at the entity level.
    ///
    /// Building every primitive at size 1 and scaling via the transform means
    /// the cache has one entry per shape rather than one per size, and it
    /// makes `BlockShape.unitBounds` the single source of truth for how big a
    /// block is — the same numbers picking and physics use.
    ///
    /// The graphics setting decides how detailed: rounded box edges and
    /// many-sided curves on High, plain boxes and fewer sides below it. In a
    /// world of a thousand parts that is most of the triangles on screen.
    public static func mesh(for shape: BlockShape, profile: GraphicsProfile = .profile(for: .high)) -> MeshResource {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let key = MeshKey(shape: shape, smooth: profile.smoothShapes, segments: profile.roundSegments, rings: profile.sphereRings)
        if let cached = meshCache[key] { return cached }

        let mesh: MeshResource
        switch shape {
        case .box:
            mesh = profile.smoothShapes ? .generateBox(size: 1, cornerRadius: 0.02) : .generateBox(size: 1)
        case .sphere:
            mesh = profile.smoothShapes
                ? .generateSphere(radius: 0.5)
                : ProceduralMesh.sphere(radius: 0.5, rings: profile.sphereRings, segments: profile.roundSegments)
        case .cylinder:
            mesh = ProceduralMesh.cylinder(height: 1, radius: 0.5, segments: profile.roundSegments)
        case .cone:
            mesh = ProceduralMesh.cone(height: 1, radius: 0.5, segments: profile.roundSegments)
        case .plane:
            mesh = .generatePlane(width: 1, depth: 1)
        }
        meshCache[key] = mesh
        return mesh
    }

    // MARK: Materials

    /// Blocks of the same colour and material share one material value.
    ///
    /// A world built from a palette of a dozen colours used to create a
    /// material per block; handing RealityKit the same one lets it keep the
    /// state it needs to draw them once rather than once per part.
    private struct MaterialKey: Hashable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var kind: MaterialKind
        /// How many times a pattern repeats across the block.
        var tiles: UInt8
        var picture: UUID?
        var mark: MeaningMark?
    }

    private static var materialCache: [MaterialKey: RealityKit.Material] = [:]

    private static var _marksMeaning = false
    /// Settings → Colour vision: dangers striped and goals checked, for parts
    /// built from now on.
    public static var marksMeaning: Bool {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return _marksMeaning
        }
        set {
            cacheLock.lock()
            _marksMeaning = newValue
            cacheLock.unlock()
        }
    }

    public static func material(for block: BlockData, picture: WorldImage? = nil) -> RealityKit.Material {
        material(for: block, picture: picture, merged: false).material
    }

    /// The material for a block drawn as part of a merged mesh, and a key
    /// that is the same for every block that can share it. The pattern
    /// repeats once: each block's own repeats are baked into its texture
    /// coordinates (`textureRepeats`), so a long wall and a small crate of
    /// the same brick share one material.
    public static func mergedMaterial(for block: BlockData) -> (key: AnyHashable, material: RealityKit.Material) {
        let made = material(for: block, picture: nil, merged: true)
        return (AnyHashable(made.key), made.material)
    }

    /// Whether what the block does is drawn on it (Settings → Colour vision).
    public static func isMarked(_ block: BlockData) -> Bool {
        marksMeaning && MeaningMark.mark(for: block.behavior) != nil
    }

    /// How many times a block's pattern repeats across it.
    public static func textureRepeats(for block: BlockData) -> Float {
        let marked = marksMeaning && MeaningMark.mark(for: block.behavior) != nil
        return Float(tileCount(for: block, marked: marked))
    }

    private static func material(for block: BlockData, picture: WorldImage?, merged: Bool) -> (key: MaterialKey, material: RealityKit.Material) {
        let alpha: Float = block.color.a * block.material.alphaScale
        // Read before the cache lock: `marksMeaning` takes the same lock.
        let mark: MeaningMark? = picture == nil && marksMeaning ? MeaningMark.mark(for: block.behavior) : nil
        let tiles: UInt8 = merged ? 1 : tileCount(for: block, marked: mark != nil)
        let key = MaterialKey(r: byte(block.color.r), g: byte(block.color.g), b: byte(block.color.b), a: byte(alpha),
                              kind: block.material, tiles: tiles, picture: picture?.id, mark: mark)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = materialCache[key] { return (key, cached) }

        let made = makeMaterial(for: block, alpha: alpha, tiles: tiles, picture: picture, mark: mark)
        // A script recolouring blocks every tick could otherwise grow this
        // forever; a few thousand colours is far more than any world uses.
        if materialCache.count > 4096 { materialCache.removeAll() }
        materialCache[key] = made
        return (key, made)
    }

    private static func byte(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        let scaled: Float = (value * 255).rounded()
        return UInt8(Swift.max(0, Swift.min(255, scaled)))
    }

    /// A pattern repeats about every two metres, so a long wall has many
    /// bricks rather than a few stretched ones.
    private static func tileCount(for block: BlockData, marked: Bool) -> UInt8 {
        guard block.material.pattern != .none || marked else { return 1 }
        let span: Float = Swift.max(block.scale.x, block.scale.z, block.scale.y * 0.5)
        let halved: Float = (span.isFinite ? span : 1) / 2
        return UInt8(Swift.max(1, Swift.min(24, halved)).rounded())
    }

    // Each kind of material in its own function, so the compiler checks
    // them one at a time; as one function this was among the slowest things
    // in the app to compile.
    private static func makeMaterial(for block: BlockData, alpha: Float, tiles: UInt8,
                                     picture: WorldImage?, mark: MeaningMark?) -> RealityKit.Material {
        let tint = UIColor(
            red: CGFloat(block.color.r),
            green: CGFloat(block.color.g),
            blue: CGFloat(block.color.b),
            alpha: CGFloat(alpha)
        )
        if let picture, let texture = SurfaceTextures.texture(for: picture) {
            return pictureMaterial(texture, alpha: alpha)
        }
        if let mark, let texture = SurfaceTextures.texture(for: mark) {
            return markedMaterial(texture, block: block, tint: tint, alpha: alpha, tiles: tiles)
        }
        if !block.material.isUnlit, block.material.pattern != .none,
           let texture = SurfaceTextures.texture(for: block.material.pattern) {
            return patternMaterial(texture, block: block, tint: tint, alpha: alpha, tiles: tiles)
        }
        if block.material.isUnlit {
            // Neon reads as emissive without needing a light probe, which
            // keeps it bright in the Studio's flat editor lighting too.
            var unlit = UnlitMaterial(color: tint)
            unlit.blending = alpha < 0.999 ? .transparent(opacity: .init(floatLiteral: alpha)) : .opaque
            return unlit
        }
        var material = SimpleMaterial()
        material.color = .init(tint: tint)
        material.roughness = .init(floatLiteral: block.material.roughness)
        material.metallic = .init(floatLiteral: block.material.isMetallic ? 1.0 : 0.0)
        return material
    }

    /// The picture as it is, on every side.
    private static func pictureMaterial(_ texture: TextureResource, alpha: Float) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        material.roughness = .init(floatLiteral: 0.7)
        material.metallic = .init(floatLiteral: 0)
        if alpha < 0.999 { material.blending = .transparent(opacity: .init(floatLiteral: alpha)) }
        return material
    }

    /// What the part does, drawn on it, whatever it is made of.
    private static func markedMaterial(_ texture: TextureResource, block: BlockData, tint: UIColor,
                                       alpha: Float, tiles: UInt8) -> RealityKit.Material {
        let solid: UIColor = tint.withAlphaComponent(1)
        let repeating = MaterialParameters.Texture(texture, sampler: SurfaceTextures.repeatingSampler)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: solid, texture: repeating)
        material.roughness = .init(floatLiteral: block.material.roughness)
        material.metallic = .init(floatLiteral: 0)
        if block.material.isUnlit {
            material.emissiveColor = .init(color: solid, texture: repeating)
            material.emissiveIntensity = 0.6
        }
        material.textureCoordinateTransform = .init(offset: .zero, scale: SIMD2<Float>(repeating: Float(tiles)), rotation: 0)
        if alpha < 0.999 { material.blending = .transparent(opacity: .init(floatLiteral: alpha)) }
        return material
    }

    private static func patternMaterial(_ texture: TextureResource, block: BlockData, tint: UIColor,
                                        alpha: Float, tiles: UInt8) -> RealityKit.Material {
        let repeating = MaterialParameters.Texture(texture, sampler: SurfaceTextures.repeatingSampler)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: tint.withAlphaComponent(1), texture: repeating)
        material.roughness = .init(floatLiteral: block.material.roughness)
        material.metallic = .init(floatLiteral: 0)
        material.textureCoordinateTransform = .init(offset: .zero, scale: SIMD2<Float>(repeating: Float(tiles)), rotation: 0)
        if alpha < 0.999 { material.blending = .transparent(opacity: .init(floatLiteral: alpha)) }
        return material
    }

    // MARK: Entity construction

    /// Builds the entity for a block, without attaching it to a parent.
    public static func makeEntity(for block: BlockData, profile: GraphicsProfile = .profile(for: .high),
                                  collisionShapes: Bool = true, picture: WorldImage? = nil) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh(for: block.shape, profile: profile), materials: [material(for: block, picture: picture)])
        entity.name = block.name
        apply(block, to: entity, physicsEnabled: false, collisionShapes: collisionShapes, picture: picture)
        return entity
    }

    /// Updates an existing entity in place.
    ///
    /// Reusing entities rather than rebuilding them matters in the Studio,
    /// where a drag produces a transform update every frame: rebuilding would
    /// mean re-uploading a mesh sixty times a second.
    ///
    /// `collisionShapes` is false in a game: movement, shots and taps are all
    /// worked out from the world document (`WorldIndex`), so RealityKit
    /// keeping a collider per part is work nothing reads.
    public static func apply(_ block: BlockData, to entity: ModelEntity, physicsEnabled: Bool, collisionShapes: Bool = true,
                             picture: WorldImage? = nil) {
        entity.name = block.name
        entity.transform = block.transform.realityKit
        entity.isEnabled = block.isVisible

        entity.model?.materials = [material(for: block, picture: picture)]
        entity.components.set(BlockComponent(blockID: block.id, behavior: block.behavior))

        if collisionShapes || physicsEnabled {
            configureCollision(block, on: entity, physicsEnabled: physicsEnabled)
        } else {
            entity.components.remove(CollisionComponent.self)
            entity.components.remove(PhysicsBodyComponent.self)
        }
    }

    private static func configureCollision(_ block: BlockData, on entity: ModelEntity, physicsEnabled: Bool) {
        guard block.hasCollision else {
            entity.components.remove(CollisionComponent.self)
            entity.components.remove(PhysicsBodyComponent.self)
            return
        }

        // The collider is built from the shape's unit bounds and then scaled
        // by the entity transform, so it always matches what is drawn.
        let size = block.shape.unitBounds.size
        let shapeResource: ShapeResource
        switch block.shape {
        case .sphere:
            shapeResource = .generateSphere(radius: 0.5)
        case .box, .cylinder, .cone, .plane:
            // RealityKit has no cylinder or cone collider; a box is the
            // closest primitive and is what a player's feet land on anyway.
            shapeResource = .generateBox(size: SIMD3<Float>(size.x, size.y, size.z))
        }

        // Blocks the player only needs to *notice* (coins, checkpoints) are
        // triggers: they fire on contact but do not stop movement.
        let isTrigger = block.behavior == .collectible || block.behavior == .checkpoint

        entity.components.set(CollisionComponent(
            shapes: [shapeResource],
            mode: isTrigger ? .trigger : .default,
            filter: .default
        ))

        guard physicsEnabled else {
            entity.components.remove(PhysicsBodyComponent.self)
            return
        }

        entity.components.set(PhysicsBodyComponent(
            shapes: [shapeResource],
            mass: block.isAnchored ? 0 : 1,
            material: .generate(friction: 0.6, restitution: 0.1),
            mode: block.isAnchored ? .static : .dynamic
        ))
    }

    // MARK: Selection highlight

    private static let highlightName = "ablox.selection.highlight"

    /// Wraps the block in a slightly larger wireframe-ish shell so the
    /// selection reads clearly against any block colour.
    public static func setHighlight(_ highlighted: Bool, on entity: ModelEntity) {
        let existing = entity.children.first { $0.name == highlightName }

        guard highlighted else {
            existing?.removeFromParent()
            return
        }
        guard existing == nil else { return }

        var material = UnlitMaterial(color: UIColor.cyan.withAlphaComponent(0.28))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.28))

        // Uses the same mesh as the block, scaled up a touch, so the outline
        // follows spheres and cones rather than boxing them.
        guard let model = entity.model else { return }
        let shell = ModelEntity(mesh: model.mesh, materials: [material])
        shell.name = highlightName
        shell.scale = SIMD3<Float>(repeating: 1.06)
        entity.addChild(shell)
    }
}

#if canImport(UIKit)
import UIKit
#endif
