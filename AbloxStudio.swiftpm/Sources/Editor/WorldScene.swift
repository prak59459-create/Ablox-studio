import Foundation
import RealityKit
import simd
import AbloxCore

/// Keeps a RealityKit scene in step with a `WorldDocument`.
///
/// The document is the truth; this class reconciles the scene against it. A
/// diff-and-patch approach rather than rebuild-from-scratch, because the
/// Studio calls `sync` on every frame of a drag and multiplayer calls it on
/// every delta — tearing down and re-adding two hundred entities at 60 Hz
/// would drop frames and lose RealityKit's internal caches.
public final class WorldScene {

    public let root = Entity()

    private var entities: [UUID: ModelEntity] = [:]
    private var lastAppliedBlocks: [UUID: BlockData] = [:]
    private var lastEnvironment: EnvironmentSettings?
    private var physicsEnabled = false

    private let lightingAnchor = AnchorEntity(world: .zero)
    private var sunLight: DirectionalLight?
    private var groundEntity: ModelEntity?

    public init() {
        root.name = "ablox.world"
        lightingAnchor.addChild(root)
    }

    /// The anchor to add to `ARView.scene`.
    public var anchor: AnchorEntity { lightingAnchor }

    // MARK: Sync

    /// Reconciles the scene against `world`.
    ///
    /// - Parameter physicsEnabled: true in Play mode. In Edit mode blocks must
    ///   not fall over while you are arranging them, so physics bodies are
    ///   left off entirely rather than being made kinematic.
    public func sync(to world: WorldDocument, physicsEnabled: Bool) {
        let physicsChanged = physicsEnabled != self.physicsEnabled
        self.physicsEnabled = physicsEnabled

        syncEnvironment(world.environment)

        var seen = Set<UUID>()

        // Parents must exist before children can be attached to them, so walk
        // the tree top-down rather than iterating the flat array.
        var queue: [BlockData] = world.rootBlocks
        while let block = queue.first {
            queue.removeFirst()
            seen.insert(block.id)
            upsert(block, in: world, physicsChanged: physicsChanged)
            queue.append(contentsOf: world.children(of: block.id))
        }

        // Any block in the flat array we never reached is orphaned by a
        // dangling parent link. Render it at the top level rather than
        // silently dropping it — an invisible block is a confusing bug,
        // a misplaced one is an obvious `validate()` warning.
        for block in world.blocks where !seen.contains(block.id) {
            seen.insert(block.id)
            upsert(block, in: world, physicsChanged: physicsChanged, forceTopLevel: true)
        }

        for (id, entity) in entities where !seen.contains(id) {
            entity.removeFromParent()
            entities.removeValue(forKey: id)
            lastAppliedBlocks.removeValue(forKey: id)
        }
    }

    private func upsert(_ block: BlockData, in world: WorldDocument, physicsChanged: Bool, forceTopLevel: Bool = false) {
        let entity: ModelEntity
        if let existing = entities[block.id] {
            entity = existing
            // Skip untouched blocks: the common case during a drag is that
            // one block changed and the rest did not.
            if !physicsChanged, lastAppliedBlocks[block.id] == block, entity.parent != nil {
                reparentIfNeeded(entity, block: block, forceTopLevel: forceTopLevel)
                return
            }
        } else {
            entity = BlockEntityFactory.makeEntity(for: block)
            entities[block.id] = entity
        }

        BlockEntityFactory.apply(block, to: entity, physicsEnabled: physicsEnabled && block.hasCollision)
        lastAppliedBlocks[block.id] = block
        reparentIfNeeded(entity, block: block, forceTopLevel: forceTopLevel)
    }

    private func reparentIfNeeded(_ entity: ModelEntity, block: BlockData, forceTopLevel: Bool) {
        let desiredParent: Entity
        if !forceTopLevel, let parentID = block.parentID, let parentEntity = entities[parentID] {
            desiredParent = parentEntity
        } else {
            desiredParent = root
        }
        if entity.parent !== desiredParent {
            // setParent preserves the local transform, which is what we want:
            // BlockData.transform is already local to its parent.
            entity.setParent(desiredParent, preservingWorldTransform: false)
        }
    }

    // MARK: Environment

    private func syncEnvironment(_ environment: EnvironmentSettings) {
        guard environment != lastEnvironment else { return }
        lastEnvironment = environment

        let light: DirectionalLight
        if let existing = sunLight {
            light = existing
        } else {
            light = DirectionalLight()
            light.light.color = .white
            light.shadow = DirectionalLightComponent.Shadow(maximumDistance: 40, depthBias: 1.5)
            lightingAnchor.addChild(light)
            sunLight = light
        }

        light.light.intensity = 2000 * max(0.1, environment.ambientIntensity)
        light.orientation = Quat.euler(degrees: Vec3(environment.sunPitchDegrees, environment.sunYawDegrees, 0)).simd

        syncGround(environment)
    }

    private func syncGround(_ environment: EnvironmentSettings) {
        guard environment.showGroundPlane else {
            groundEntity?.removeFromParent()
            groundEntity = nil
            return
        }

        let colour = UIColor(
            red: CGFloat(environment.groundColor.r),
            green: CGFloat(environment.groundColor.g),
            blue: CGFloat(environment.groundColor.b),
            alpha: 1
        )

        if let ground = groundEntity {
            var material = SimpleMaterial()
            material.color = .init(tint: colour)
            material.roughness = .init(floatLiteral: 1.0)
            ground.model?.materials = [material]
            return
        }

        var material = SimpleMaterial()
        material.color = .init(tint: colour)
        material.roughness = .init(floatLiteral: 1.0)

        // A large backdrop plane sitting just below y=0, so worlds without a
        // floor block still have something to stand on and the horizon reads
        // as ground rather than void. Non-colliding: the authored floor block
        // is what the player actually walks on.
        let ground = ModelEntity(mesh: .generatePlane(width: 400, depth: 400), materials: [material])
        ground.name = "ablox.ground"
        ground.position = SIMD3<Float>(0, -0.05, 0)
        lightingAnchor.addChild(ground)
        groundEntity = ground
    }

    // MARK: Lookup

    public func entity(for blockID: UUID) -> ModelEntity? {
        entities[blockID]
    }

    /// Walks up from a hit-test result to the owning block.
    public func blockID(forHit entity: Entity) -> UUID? {
        var cursor: Entity? = entity
        while let current = cursor {
            if let component = current.components[BlockComponent.self] as BlockComponent? {
                return component.blockID
            }
            cursor = current.parent
        }
        return nil
    }

    public func setHighlight(_ highlighted: Bool, forBlock id: UUID) {
        guard let entity = entities[id] else { return }
        BlockEntityFactory.setHighlight(highlighted, on: entity)
    }

    public func clearAllHighlights() {
        for entity in entities.values {
            BlockEntityFactory.setHighlight(false, on: entity)
        }
    }

    public func removeAll() {
        for entity in entities.values { entity.removeFromParent() }
        entities.removeAll()
        lastAppliedBlocks.removeAll()
    }

    // MARK: Runtime effects

    /// Applies a broadcast effect that the document does not own — animated
    /// tints and moves, which run on the client so the host is not simulating
    /// interpolation for everyone.
    public func apply(effect: EventAction) {
        switch effect {
        case let .tint(blockID, color, duration):
            guard let entity = entities[blockID] else { return }
            guard duration > 0 else {
                applyInstantTint(color, to: entity)
                return
            }
            animateTint(to: color, on: entity, duration: duration)

        case let .move(blockID, offset, duration):
            guard let entity = entities[blockID] else { return }
            var target = entity.transform
            target.translation += SIMD3<Float>(offset)
            if duration > 0 {
                entity.move(to: target, relativeTo: entity.parent, duration: duration, timingFunction: .easeInOut)
            } else {
                entity.transform = target
            }

        case let .setVisible(blockID, visible):
            entities[blockID]?.isEnabled = visible

        case let .setCollision(blockID, enabled):
            guard let entity = entities[blockID] else { return }
            if enabled {
                // Restored from the block's own definition on the next sync;
                // removing is the only part that has to happen immediately.
                break
            } else {
                entity.components.remove(CollisionComponent.self)
                entity.components.remove(PhysicsBodyComponent.self)
            }

        case .teleportPlayer, .awardPoints, .announce, .playSound, .endRound:
            // Not scene-level: handled by the viewport and the HUD.
            break
        }
    }

    private func applyInstantTint(_ color: ColorRGBA, to entity: ModelEntity) {
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(
            red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a)
        ))
        entity.model?.materials = [material]
    }

    /// RealityKit cannot interpolate a material colour directly, so the ramp
    /// is stepped on a timer. Twenty steps a second is smooth enough for a
    /// colour fade and costs far less than a per-frame material rebuild.
    private func animateTint(to color: ColorRGBA, on entity: ModelEntity, duration: Double) {
        let steps = max(1, Int(duration * 20))
        let startColor = currentTint(of: entity) ?? color

        for step in 1...steps {
            let t = Float(step) / Float(steps)
            let delay = duration * Double(step) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak entity] in
                // Both weak: a ramp in flight must not keep the scene — or a
                // block that has since been deleted — alive until it finishes.
                guard let self, let entity, entity.parent != nil else { return }
                self.applyInstantTint(ColorRGBA.lerp(startColor, color, t), to: entity)
            }
        }
    }

    private func currentTint(of entity: ModelEntity) -> ColorRGBA? {
        guard let material = entity.model?.materials.first as? SimpleMaterial else { return nil }
        return ColorRGBA(uiColor: material.color.tint)
    }
}

#if canImport(UIKit)
import UIKit
#endif
