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
/// would drop frames and lose RealityKit's internal caches. A game goes
/// further: it looks only at the blocks that changed (`WorldChangeLog`), and
/// draws the parts that stay put as a few merged meshes (`StillPartBaker`).
public final class WorldScene {

    public let root = Entity()

    private var entities: [UUID: ModelEntity] = [:]
    private var lastAppliedBlocks: [UUID: BlockData] = [:]
    private var lastEnvironment: EnvironmentSettings?
    private var physicsEnabled = false

    private let lightingAnchor = AnchorEntity(world: .zero)
    private var sunLight: DirectionalLight?
    private var groundEntity: ModelEntity?

    /// Whether each part gets a RealityKit collider. The Studio's editor
    /// picks parts through them; a game works everything out from the
    /// document instead and leaves them off.
    private let collisionShapes: Bool
    /// How detailed the parts and shadows are — see `GraphicsProfile`.
    public private(set) var profile = GraphicsProfile.profile(for: .high)
    /// Hidden by a runtime effect rather than by the document.
    private var effectHidden: Set<UUID> = []
    /// Too far away to draw at the current view distance.
    private var culled: Set<UUID> = []
    /// Blocks with children. Never hidden for distance: hiding an entity
    /// hides everything under it, and a child can be much nearer.
    private var parentIDs: Set<UUID> = []
    /// The world picture each block shows, for putting its look back.
    private var pictures: [UUID: WorldImage] = [:]
    /// The lamps and spotlights lit, by block. At most `BlockLight.maximumLit`.
    private var lamps: [UUID: Entity] = [:]
    /// Blocks with words over them (`BlockLabel`), for the label overlay.
    private var labels: [UUID: BlockLabel] = [:]
    /// Blocks that move by themselves (`BlockAnimation`).
    private var animated: [UUID: BlockAnimation] = [:]
    /// The ones near enough to be seen moving, looked for a few times a second.
    private var animatedNearby: [UUID] = []
    private var animatedLookedAt: Double = -.infinity
    /// A game's still parts, drawn as a few merged meshes. Nil in the
    /// Studio, where every part is picked and dragged on its own.
    private var baker: StillPartBaker?

    /// Whether still parts are baked into merged meshes (a game only). The
    /// launch check's frame-rate run turns it off for a while, to compare.
    public var bakesStillParts = true {
        didSet {
            guard bakesStillParts != oldValue, let baker else { return }
            if bakesStillParts { baker.wake(lastAppliedBlocks.keys) } else { baker.dissolveAll() }
        }
    }

    /// Parts drawn by an entity of their own, for the launch check.
    public var partsDrawnOnTheirOwn: Int {
        entities.values.reduce(0) { $0 + ($1.isEnabled && $1.model != nil ? 1 : 0) }
    }

    public init(collisionShapes: Bool = true) {
        self.collisionShapes = collisionShapes
        root.name = "ablox.world"
        lightingAnchor.addChild(root)
        if !collisionShapes { baker = StillPartBaker(scene: self) }
    }

    /// The anchor to add to `ARView.scene`.
    public var anchor: AnchorEntity { lightingAnchor }

    // MARK: Sync

    /// Reconciles the scene against `world`, looking at every block.
    ///
    /// - Parameter physicsEnabled: true in Play mode. In Edit mode blocks must
    ///   not fall over while you are arranging them, so physics bodies are
    ///   left off entirely rather than being made kinematic.
    public func sync(to world: WorldDocument, physicsEnabled: Bool) {
        let physicsChanged = physicsEnabled != self.physicsEnabled
        self.physicsEnabled = physicsEnabled
        if physicsChanged, physicsEnabled { baker?.dissolveAll() }

        syncEnvironment(world.environment)

        // Nothing drawn yet: the world as it comes can be baked at once.
        let fresh = entities.isEmpty
        let blocks = world.blocks

        // Children grouped by parent once, by position in the list rather
        // than by copying blocks about — that was a search of every block,
        // per block, on every change, and then a copy of each.
        var orderByID: [UUID: Int] = [:]
        orderByID.reserveCapacity(blocks.count)
        for (order, block) in blocks.enumerated() { orderByID[block.id] = order }
        var children: [Int: [Int]] = [:]
        var topLevel: [Int] = []
        for (order, block) in blocks.enumerated() {
            if let parentID = block.parentID, let parent = orderByID[parentID] {
                children[parent, default: []].append(order)
            } else {
                topLevel.append(order)
            }
        }
        let parents = Set(children.keys.map { blocks[$0].id })
        if let baker {
            // A block with children draws on its own; one that lost its
            // last child may be baked again.
            for id in parents where !parentIDs.contains(id) { baker.forget(id) }
            for id in parentIDs where !parents.contains(id) && orderByID[id] != nil { baker.reconsider(id) }
        }
        parentIDs = parents

        // Parents must exist before children can be attached to them, so walk
        // the tree top-down rather than iterating the flat array.
        var reached = [Bool](repeating: false, count: blocks.count)
        var queue = topLevel
        var next = 0
        while next < queue.count {
            let order = queue[next]
            next += 1
            guard !reached[order] else { continue }
            reached[order] = true
            upsert(blocks[order], in: world, physicsChanged: physicsChanged, fresh: fresh)
            if let kids = children[order] { queue.append(contentsOf: kids) }
        }

        // Any block in the flat array we never reached is orphaned by a
        // dangling parent link or a parent cycle. Render it at the top level
        // rather than silently dropping it — an invisible block is a
        // confusing bug, a misplaced one is an obvious `validate()` warning.
        for order in blocks.indices where !reached[order] {
            upsert(blocks[order], in: world, physicsChanged: physicsChanged, forceTopLevel: true, fresh: fresh)
        }

        if !fresh {
            let gone = entities.keys.filter { orderByID[$0] == nil }
            for id in gone { removeBlock(id) }
        }
    }

    /// Reconciles only the blocks the world says changed (`WorldChangeLog`),
    /// found through `index`, which must be of this same world. Anything only
    /// a full look catches — a block removed or hung elsewhere — falls back
    /// to `sync(to:physicsEnabled:)`.
    public func sync(to world: WorldDocument, changes: WorldChangeLog, index: WorldIndex, physicsEnabled: Bool) {
        guard !changes.isEmpty || physicsEnabled != self.physicsEnabled else {
            syncEnvironment(world.environment)
            return
        }
        guard !changes.everything, physicsEnabled == self.physicsEnabled, !entities.isEmpty else {
            sync(to: world, physicsEnabled: physicsEnabled)
            return
        }
        syncEnvironment(world.environment)
        let blocks = world.blocks
        // Blocks removed, with everything hung from them: found through
        // their entities, which hang the same way.
        for id in changes.removed {
            guard let entity = entities[id] else { continue }
            let parentID = lastAppliedBlocks[id]?.parentID
            var doomed: [UUID] = []
            Self.collectBlocks(under: entity, into: &doomed)
            for gone in doomed { removeBlock(gone) }
            if let parentID, let parent = entities[parentID],
               !parent.children.contains(where: { $0.components.has(BlockComponent.self) }) {
                // It lost its last child: it may be baked again.
                parentIDs.remove(parentID)
                baker?.forgetModel(parentID)
                baker?.reconsider(parentID)
            }
        }
        var orders: [Int] = []
        orders.reserveCapacity(changes.blocks.count)
        for id in changes.blocks {
            // Added and taken away again since the last frame.
            if changes.removed.contains(id), index.entry(for: id) == nil { continue }
            guard let entry = index.entry(for: id), entry.order < blocks.count, blocks[entry.order].id == id,
                  lastAppliedBlocks[id].map({ $0.parentID == blocks[entry.order].parentID }) ?? true else {
                sync(to: world, physicsEnabled: physicsEnabled)
                return
            }
            orders.append(entry.order)
        }
        orders.sort()
        for order in orders {
            upsert(blocks[order], in: world, physicsChanged: false, fresh: false)
        }
        // A part can come before its parent in the list: hang each from the
        // right entity once all of them exist.
        for order in orders {
            let block = blocks[order]
            guard let entity = entities[block.id] else { continue }
            if let parentID = block.parentID, entities[parentID] != nil, parentIDs.insert(parentID).inserted {
                // Something was hung from it: it draws on its own from now,
                // and is never hidden for distance.
                baker?.forget(parentID)
                if culled.remove(parentID) != nil { refreshShown(parentID) }
            }
            reparentIfNeeded(entity, block: block, forceTopLevel: false)
        }
    }

    /// Every block drawn by `entity` or hung under it.
    private static func collectBlocks(under entity: Entity, into ids: inout [UUID]) {
        if let component = entity.components[BlockComponent.self] as BlockComponent? {
            ids.append(component.blockID)
        }
        for child in entity.children {
            collectBlocks(under: child, into: &ids)
        }
    }

    private func removeBlock(_ id: UUID) {
        entities.removeValue(forKey: id)?.removeFromParent()
        lastAppliedBlocks.removeValue(forKey: id)
        effectHidden.remove(id)
        culled.remove(id)
        pictures.removeValue(forKey: id)
        lamps.removeValue(forKey: id)
        labels.removeValue(forKey: id)
        animated.removeValue(forKey: id)
        if parentIDs.remove(id) != nil { baker?.forgetModel(id) }
        baker?.forget(id)
    }

    /// Puts a lamp or spotlight in the block, or takes it out.
    private func updateLamp(_ block: BlockData, on entity: ModelEntity) {
        guard let setting = block.light else {
            lamps.removeValue(forKey: block.id)?.removeFromParent()
            return
        }
        if lamps[block.id] == nil, lamps.count >= BlockLight.maximumLit { return }
        lamps[block.id]?.removeFromParent()
        let color = UIColor(red: CGFloat(setting.color.r), green: CGFloat(setting.color.g), blue: CGFloat(setting.color.b), alpha: 1)
        let lamp: Entity
        switch setting.kind {
        case .point:
            let light = PointLight()
            light.light.color = color
            light.light.intensity = 40_000 * setting.intensity
            light.light.attenuationRadius = setting.range
            lamp = light
        case .spot:
            let light = SpotLight()
            light.light.color = color
            light.light.intensity = 60_000 * setting.intensity
            light.light.attenuationRadius = setting.range
            light.light.innerAngleInDegrees = 25
            light.light.outerAngleInDegrees = 45
            // Straight down out of the block, like a ceiling light.
            light.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            lamp = light
        }
        lamp.name = "ablox.lamp"
        // The block's size must not stretch the light.
        let scale = block.scale
        lamp.scale = SIMD3<Float>(1 / max(scale.x, 0.01), 1 / max(scale.y, 0.01), 1 / max(scale.z, 0.01))
        entity.addChild(lamp)
        lamps[block.id] = lamp
    }

    private func upsert(_ block: BlockData, in world: WorldDocument, physicsChanged: Bool, forceTopLevel: Bool = false,
                        fresh: Bool) {
        let entity: ModelEntity
        let previous = lastAppliedBlocks[block.id]
        if let existing = entities[block.id] {
            entity = existing
            // Skip untouched blocks: the common case during a drag is that
            // one block changed and the rest did not.
            if !physicsChanged, previous == block, entity.parent != nil {
                reparentIfNeeded(entity, block: block, forceTopLevel: forceTopLevel)
                return
            }
            // Only moved — a character walking, a block a script slides:
            // the entity is moved and nothing else is looked at again.
            if !physicsChanged, let previous, entity.parent != nil, RenderMerging.onlyMoved(previous, block) {
                entity.transform = block.transform.realityKit
                lastAppliedBlocks[block.id] = block
                baker?.changed(block, fresh: false)
                return
            }
        } else {
            entity = BlockEntityFactory.makeEntity(for: block, profile: profile, collisionShapes: collisionShapes,
                                                   picture: block.imageID.flatMap { world.image(id: $0) })
            entities[block.id] = entity
        }

        if let previous, previous.shape != block.shape {
            entity.model?.mesh = BlockEntityFactory.mesh(for: block.shape, profile: profile)
        }
        let picture = block.imageID.flatMap { world.image(id: $0) }
        pictures[block.id] = picture
        BlockEntityFactory.apply(block, to: entity, physicsEnabled: physicsEnabled && block.hasCollision,
                                 collisionShapes: collisionShapes, picture: picture)
        updateLamp(block, on: entity)
        if let label = block.label, !label.isEmpty { labels[block.id] = label } else { labels.removeValue(forKey: block.id) }
        if let animation = block.animation { animated[block.id] = animation } else { animated.removeValue(forKey: block.id) }
        lastAppliedBlocks[block.id] = block
        if let baker {
            showModel(of: block, on: entity, picture: picture)
            // A new name, tag or words are not a reason to rebuild a mesh.
            if previous.map({ !RenderMerging.looksTheSame($0, block) }) ?? true {
                baker.changed(block, fresh: fresh && previous == nil)
            }
        }
        entity.isEnabled = shouldShow(block.id)
        reparentIfNeeded(entity, block: block, forceTopLevel: forceTopLevel)
    }

    /// A block see-through to the end — a character's root — is not handed
    /// to the GPU at all; one that can be seen gets its mesh back.
    private func showModel(of block: BlockData, on entity: ModelEntity, picture: WorldImage?) {
        if RenderMerging.drawsNothing(block) {
            if entity.model != nil { entity.model = nil }
        } else if entity.model == nil {
            entity.model = ModelComponent(mesh: BlockEntityFactory.mesh(for: block.shape, profile: profile),
                                          materials: [BlockEntityFactory.material(for: block, picture: picture)])
        }
    }

    /// Whether a block's own entity is drawn: seen in the world, not hidden
    /// by an effect or for distance, and not drawn by a merged mesh instead.
    private func shouldShow(_ id: UUID) -> Bool {
        (lastAppliedBlocks[id]?.isVisible ?? true) && !effectHidden.contains(id) && !culled.contains(id)
            && !(baker?.isBaked(id) ?? false)
    }

    private func refreshShown(_ id: UUID) {
        guard let entity = entities[id] else { return }
        let show = shouldShow(id)
        if entity.isEnabled != show { entity.isEnabled = show }
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
            applyShadow(to: light)
            lightingAnchor.addChild(light)
            sunLight = light
        }

        light.light.intensity = 2000 * max(0.1, environment.ambientIntensity) * (1 - environment.weather.gloom)
        light.orientation = Quat.euler(degrees: Vec3(environment.sunPitchDegrees, environment.sunYawDegrees, 0)).simd
        applyShadow(to: light)

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

    // MARK: Graphics

    /// Switches to another quality level: meshes, shadows and view distance.
    public func setGraphics(_ newProfile: GraphicsProfile) {
        guard newProfile != profile else { return }
        let meshesChanged = newProfile.smoothShapes != profile.smoothShapes
            || newProfile.roundSegments != profile.roundSegments
            || newProfile.sphereRings != profile.sphereRings
        profile = newProfile
        if let sunLight { applyShadow(to: sunLight) }
        if meshesChanged {
            for (id, entity) in entities {
                guard let block = lastAppliedBlocks[id] else { continue }
                entity.model?.mesh = BlockEntityFactory.mesh(for: block.shape, profile: profile)
            }
            baker?.shapesChanged()
        }
        if profile.viewDistance == nil { showAllCulled() }
    }

    private func applyShadow(to light: DirectionalLight) {
        // The world can turn its shadows off; the graphics setting can too.
        let wanted = lastEnvironment?.shadows ?? true
        light.shadow = wanted ? profile.shadowDistance.map { DirectionalLightComponent.Shadow(maximumDistance: $0, depthBias: 1.5) } : nil
    }

    /// The sun where the time of day puts it, and as bright as the day is.
    /// The game calls this as the day passes; the Studio never does, so the
    /// editor keeps the light the world was built with.
    public func setDaylight(pitch: Float, yaw: Float, brightness: Float) {
        guard let light = sunLight else { return }
        let intensity = 2000 * max(0.05, brightness)
        if abs(light.light.intensity - intensity) > 1 { light.light.intensity = intensity }
        light.orientation = Quat.euler(degrees: Vec3(pitch, yaw, 0)).simd
    }

    /// Moves a block's drawing without changing the document — a moving
    /// platform, placed by the clock every frame.
    public func place(_ blockID: UUID, at position: Vec3) {
        entities[blockID]?.position = position.simd
    }

    /// Hides parts further than the view distance from `eye`, and shows the
    /// ones that have come back into range. Called a few times a second,
    /// not every frame: nobody walks 80 m in a quarter of a second.
    public func cull(from eye: Vec3, index: WorldIndex) {
        guard let distance = profile.viewDistance else { return }
        let limit = distance * distance
        for (id, entity) in entities {
            // Baked parts are hidden with their mesh, below.
            guard !parentIDs.contains(id), baker?.isBaked(id) != true, let bounds = index.bounds(of: id) else { continue }
            let far = bounds.distanceSquared(to: eye) > limit
            if far {
                if culled.insert(id).inserted { entity.isEnabled = false }
            } else if culled.remove(id) != nil {
                entity.isEnabled = shouldShow(id)
            }
        }
        baker?.cull(from: eye, limit: limit, index: index)
    }

    private func showAllCulled() {
        let shown = culled
        culled.removeAll()
        for id in shown { refreshShown(id) }
        baker?.showAll()
    }

    // MARK: Merged meshes

    /// Builds a few merged meshes, within a slice of the frame. The game
    /// calls this every frame.
    public func update() {
        baker?.update()
    }

    /// Meshes drawn for many parts, and how many parts they draw.
    public var mergedSummary: (meshes: Int, parts: Int) {
        baker?.summary ?? (0, 0)
    }

    /// Time spent painting colour palettes since the last call.
    public func takePaintingSeconds() -> Double {
        baker?.takePaintingSeconds() ?? 0
    }

    func appliedBlock(_ id: UUID) -> BlockData? {
        lastAppliedBlocks[id]
    }

    /// Which merged mesh a part can be drawn by, or nil if it must be drawn
    /// on its own.
    func bakingPlace(for id: UUID) -> StillPartBaker.Place? {
        guard bakesStillParts, !physicsEnabled, let block = lastAppliedBlocks[id], let entity = entities[id], !effectHidden.contains(id),
              RenderMerging.canMerge(block, hasChildren: parentIDs.contains(id)) else { return nil }
        if let parentID = block.parentID {
            // Hung from its parent's entity, so a mesh under it moves with it.
            guard let parent = entities[parentID], entity.parent === parent else { return nil }
            return .model(parentID)
        }
        guard entity.parent === root else { return nil }
        return .patch(RenderMerging.patch(containing: block.position))
    }

    /// The entity a merged mesh hangs from.
    func bakingParent(for place: StillPartBaker.Place) -> Entity? {
        switch place {
        case .patch: return root
        case let .model(parentID): return entities[parentID]
        }
    }

    /// A part went into a mesh or came out of one: its own entity off or on.
    func bakedStateChanged(_ id: UUID) {
        refreshShown(id)
    }

    // MARK: Lookup

    public func entity(for blockID: UUID) -> ModelEntity? {
        entities[blockID]
    }

    /// Whether a block is in the scene and drawn, by its own entity or by a
    /// merged mesh (its entity is off then, but still where the block is).
    public func isDrawn(_ blockID: UUID) -> Bool {
        guard let entity = entities[blockID], entity.parent != nil else { return false }
        return entity.isEnabled || (baker?.isBaked(blockID) ?? false)
    }

    /// Every block with words over it, and the words.
    public var labeledBlocks: [UUID: BlockLabel] {
        labels
    }

    /// Turns and stretches each block that moves by itself, for `time`
    /// seconds: only those within `range` of `eye` (the graphics level's
    /// `animationRange` when nil), since a far one would not be seen moving.
    /// Which ones are near is looked at four times a second, not every
    /// frame. Never moves a block, so a `move_to` carries on. Nothing goes
    /// over the network: every iPad does this for itself.
    public func animateBlocks(time: Double, eye: Vec3, range: Float? = nil) {
        guard !animated.isEmpty else {
            animatedNearby.removeAll()
            return
        }
        if time - animatedLookedAt >= 0.25 || time < animatedLookedAt {
            animatedLookedAt = time
            let reach = range ?? profile.animationRange
            let limit = reach * reach
            animatedNearby.removeAll(keepingCapacity: true)
            for id in animated.keys {
                guard let entity = entities[id], entity.isEnabled else { continue }
                let offset = Vec3(entity.position(relativeTo: nil)) - eye
                if offset.lengthSquared < limit { animatedNearby.append(id) }
            }
        }
        for id in animatedNearby {
            guard let animation = animated[id], let entity = entities[id], let block = lastAppliedBlocks[id] else { continue }
            // Each block starts its own way through, so a row of them is not in step.
            let phase = Double(id.uuid.0) / 255 + Double(id.uuid.1) / 65_025
            let pose = animation.pose(at: time, phase: phase)
            entity.orientation = (block.transform.rotation * Quat.euler(degrees: pose.degrees)).simd
            entity.scale = (block.transform.scale * pose.stretch).simd
        }
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
        baker?.removeAll()
        for entity in entities.values { entity.removeFromParent() }
        entities.removeAll()
        lastAppliedBlocks.removeAll()
        effectHidden.removeAll()
        culled.removeAll()
        parentIDs.removeAll()
        pictures.removeAll()
        lamps.removeAll()
        labels.removeAll()
        animated.removeAll()
        animatedNearby.removeAll()
    }

    // MARK: Runtime effects

    /// Applies a broadcast effect that the document does not own — animated
    /// tints and moves, which run on the client so the host is not simulating
    /// interpolation for everyone.
    public func apply(effect: EventAction) {
        switch effect {
        case let .tint(blockID, color, duration):
            guard let entity = entities[blockID] else { return }
            // Coloured on its own, not in a merged mesh, until the world
            // next changes it.
            baker?.pin(blockID)
            guard duration > 0 else {
                applyInstantTint(color, to: entity)
                return
            }
            animateTint(to: color, on: entity, duration: duration)

        case let .move(blockID, offset, duration):
            guard let entity = entities[blockID] else { return }
            baker?.pin(blockID)
            var target = entity.transform
            target.translation += SIMD3<Float>(offset)
            if duration > 0 {
                entity.move(to: target, relativeTo: entity.parent, duration: duration, timingFunction: .easeInOut)
            } else {
                entity.transform = target
            }

        case let .setVisible(blockID, visible):
            if visible {
                effectHidden.remove(blockID)
                baker?.reconsider(blockID)
            } else {
                effectHidden.insert(blockID)
                baker?.pin(blockID)
            }
            refreshShown(blockID)
            // A door or a vanishing platform faded before it went; it comes
            // back looking as it was built, texture and all.
            if visible, let entity = entities[blockID], let block = lastAppliedBlocks[blockID] {
                entity.model?.materials = [BlockEntityFactory.material(for: block, picture: pictures[blockID])]
            }

        case let .setCollision(blockID, enabled):
            // Only the removal has to happen now — a floor that vanishes must
            // stop holding the player up this frame. Re-enabling is picked up
            // from the block's own definition on the next sync, which rebuilds
            // the collider with the right shape.
            guard !enabled, let entity = entities[blockID] else { return }
            entity.components.remove(CollisionComponent.self)
            entity.components.remove(PhysicsBodyComponent.self)

        case .teleportPlayer, .bouncePlayer, .awardPoints, .announce, .playSound, .endRound, .script:
            // Not scene-level: these act on the player or the HUD, and the
            // viewport owns both. Listed rather than a `default:` so that
            // adding an action forces this decision again — which is exactly
            // how `.bouncePlayer` was caught after Task 4 added it.
            break
        }
    }

    private func applyInstantTint(_ color: ColorRGBA, to entity: ModelEntity) {
        // A fresh material, never the shared one from `BlockEntityFactory`:
        // tinting that would repaint every block of the same colour.
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
