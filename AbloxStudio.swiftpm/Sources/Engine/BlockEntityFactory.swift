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
    }

    private static var materialCache: [MaterialKey: RealityKit.Material] = [:]

    public static func material(for block: BlockData) -> RealityKit.Material {
        let alpha = block.color.a * block.material.alphaScale
        func byte(_ value: Float) -> UInt8 { value.isFinite ? UInt8(max(0, min(255, (value * 255).rounded()))) : 0 }
        let key = MaterialKey(r: byte(block.color.r), g: byte(block.color.g), b: byte(block.color.b), a: byte(alpha),
                              kind: block.material)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = materialCache[key] { return cached }

        let tint = UIColor(
            red: CGFloat(block.color.r),
            green: CGFloat(block.color.g),
            blue: CGFloat(block.color.b),
            alpha: CGFloat(alpha)
        )

        let made: RealityKit.Material
        if block.material.isUnlit {
            // Neon reads as emissive without needing a light probe, which
            // keeps it bright in the Studio's flat editor lighting too.
            var unlit = UnlitMaterial(color: tint)
            unlit.blending = alpha < 0.999 ? .transparent(opacity: .init(floatLiteral: alpha)) : .opaque
            made = unlit
        } else {
            var material = SimpleMaterial()
            material.color = .init(tint: tint)
            material.roughness = .init(floatLiteral: block.material.roughness)
            material.metallic = .init(floatLiteral: block.material.isMetallic ? 1.0 : 0.0)
            made = material
        }
        // A script recolouring blocks every tick could otherwise grow this
        // forever; a few thousand colours is far more than any world uses.
        if materialCache.count > 4096 { materialCache.removeAll() }
        materialCache[key] = made
        return made
    }

    // MARK: Entity construction

    /// Builds the entity for a block, without attaching it to a parent.
    public static func makeEntity(for block: BlockData, profile: GraphicsProfile = .profile(for: .high),
                                  collisionShapes: Bool = true) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh(for: block.shape, profile: profile), materials: [material(for: block)])
        entity.name = block.name
        apply(block, to: entity, physicsEnabled: false, collisionShapes: collisionShapes)
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
    public static func apply(_ block: BlockData, to entity: ModelEntity, physicsEnabled: Bool, collisionShapes: Bool = true) {
        entity.name = block.name
        entity.transform = block.transform.realityKit
        entity.isEnabled = block.isVisible

        entity.model?.materials = [material(for: block)]
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
