import Foundation
import RealityKit
import UIKit
import CoreGraphics
import Metal
import simd
import QuartzCore
import AbloxCore

/// Bakes the parts of a game that stay put into a few merged meshes, so the
/// iPad draws a handful of things instead of thousands (`RenderMerging`
/// says why and which parts).
///
/// Parts at the top of the map go into a mesh per patch of map and per
/// colour and material; parts hung from a block (a character's eighteen,
/// a building's walls) into a mesh per colour under that block, so they
/// still move, turn and go away with it. A baked part keeps its own entity,
/// switched off: anything that changes it takes it out of its mesh and
/// switches its entity back on, and it may go back in once it has stayed the
/// same for a while.
///
/// A mesh is only rebuilt between frames, a few each frame, and a part
/// leaving one keeps being drawn by it until the rebuilt mesh is ready — so
/// nothing is ever drawn twice or missing for a frame.
final class StillPartBaker {

    enum Place: Hashable {
        case patch(RenderMerging.Patch)
        case model(UUID)
    }

    struct GroupKey: Hashable {
        var place: Place
        var material: AnyHashable
    }

    final class Group {
        let key: GroupKey
        /// The colour's material, or for parts coloured from the palette,
        /// their kind's palette material (set again when the palette grows).
        var material: RealityKit.Material
        /// Parts of any plain colour, coloured from the palette.
        let paletteKind: MaterialKind?
        /// Drawn by the mesh once it is next built.
        var members: Set<UUID> = []
        /// Drawn by the mesh as it stands.
        var drawn: Set<UUID> = []
        var entity: ModelEntity?
        /// Where a patch's parts are, for hiding it with distance.
        var bounds: BoundingBox?
        var isCulled = false

        init(key: GroupKey, material: RealityKit.Material, paletteKind: MaterialKind? = nil) {
            self.key = key
            self.material = material
            self.paletteKind = paletteKind
        }
    }

    /// What the baker needs from the scene.
    unowned let scene: WorldScene

    private var groups: [GroupKey: Group] = [:]
    /// The group each part is in.
    private var groupOf: [UUID: GroupKey] = [:]
    /// Parts a mesh is drawing: their own entities are off.
    private(set) var baked: Set<UUID> = []
    /// Parts that may go into a mesh, and from when.
    private var waiting: [UUID: Double] = [:]
    /// How often each part has been taken out again, so one that keeps
    /// changing waits longer each time before going back in.
    private var timesTakenOut: [UUID: Int] = [:]
    private var heldUntil: [UUID: Double] = [:]
    /// Drawn differently from the world by an effect (a tint, a slide)
    /// until the world next changes it.
    private var pinned: Set<UUID> = []
    /// Groups to rebuild: parts leaving first, then parts joining.
    private var leaving: Set<GroupKey> = []
    private var joining: Set<GroupKey> = []
    private var lastLook: Double = -.infinity
    /// Plain colours as spots on one texture, so a character of six colours
    /// is one mesh rather than six (`ColorPalette`).
    private var palette = ColorPalette()
    /// How many colours the palette texture has, and the materials made
    /// from it, by kind.
    private var paletteShown = -1
    private var paletteMaterials: [MaterialKind: RealityKit.Material] = [:]
    /// The texture could not be made: every colour gets its own mesh again.
    private var paletteFailed = false
    /// The palette texture as shown, painted again in place when a part's
    /// own spot changes colour (`recoloured`).
    private var paletteTexture: TextureResource?
    private var paletteRepainted = false
    /// Spots of parts' own, the ones free to give out again, and the ones
    /// freed but perhaps still drawn by a mesh until it is rebuilt.
    private var ownSlots: [UUID: Int] = [:]
    private var freeSlots: [Int] = []
    private var releasing: [Int] = []
    static let mostOwnSlots = 1_024

    /// Seconds a part must stay the same before it is baked: longer on the
    /// map, where a rebuild is bigger, than on a character.
    static let patchSettle: Double = 3
    static let modelSettle: Double = 0.6

    init(scene: WorldScene) {
        self.scene = scene
    }

    private var now: Double { CACurrentMediaTime() }

    func isBaked(_ id: UUID) -> Bool {
        baked.contains(id)
    }

    // MARK: Told by the scene

    /// A part was added or changed. `fresh`: it came with the world, which
    /// is baked straight away.
    func changed(_ block: BlockData, fresh: Bool) {
        let id = block.id
        pinned.remove(id)
        if groupOf[id] != nil { takeOut(id, hold: !fresh) }
        let settle = block.parentID == nil ? Self.patchSettle : Self.modelSettle
        let time = now
        waiting[id] = fresh ? time : Swift.max(time + settle, heldUntil[id] ?? 0)
    }

    /// Only its colour changed (`RenderMerging.onlyRecoloured`): a part in
    /// a palette mesh stays in it and its own spot is painted again, at
    /// once and without building the mesh again after the first time.
    /// False when it cannot be — not in a palette mesh, or no spot left —
    /// and then it is `changed` as any other.
    func recoloured(_ block: BlockData) -> Bool {
        let id = block.id
        guard !paletteFailed, let key = groupOf[id], groups[key]?.paletteKind != nil else { return false }
        if let slot = ownSlots[id] {
            if palette.repaint(slot: slot, to: block.color) { paletteRepainted = true }
            return true
        }
        guard ownSlots.count < Self.mostOwnSlots, let slot = freeSlots.popLast() ?? palette.ownSlot(block.color) else {
            return false
        }
        palette.repaint(slot: slot, to: block.color)
        ownSlots[id] = slot
        paletteRepainted = true
        // Its vertices point at its own spot from the next build, straight away.
        leaving.insert(key)
        return true
    }

    /// Something not in the world changed how a part looks — a tint, a
    /// slide, hidden by an effect: drawn on its own until the world next
    /// changes it.
    func pin(_ id: UUID) {
        pinned.insert(id)
        waiting.removeValue(forKey: id)
        if groupOf[id] != nil { takeOut(id, hold: false) }
    }

    /// May be baked again once it has stayed the same for a while (a block
    /// shown again, or one that lost its last child).
    func reconsider(_ id: UUID) {
        guard groupOf[id] == nil else { return }
        pinned.remove(id)
        waiting[id] = Swift.max(now + Self.patchSettle, heldUntil[id] ?? 0)
    }

    /// Gone from the world, or must be drawn on its own for good (it has
    /// children now).
    func forget(_ id: UUID) {
        if groupOf[id] != nil { takeOut(id, hold: false) }
        waiting.removeValue(forKey: id)
        heldUntil.removeValue(forKey: id)
        timesTakenOut.removeValue(forKey: id)
        pinned.remove(id)
    }

    /// The block itself is gone: the meshes hung from it went with it.
    func forgetModel(_ parentID: UUID) {
        for (key, group) in groups where key.place == .model(parentID) {
            group.entity?.removeFromParent()
            for id in group.members.union(group.drawn) {
                groupOf.removeValue(forKey: id)
                releaseSlot(of: id)
                if baked.remove(id) != nil { scene.bakedStateChanged(id) }
            }
            groups.removeValue(forKey: key)
            leaving.remove(key)
            joining.remove(key)
        }
    }

    /// Every part back on its own — RealityKit physics is on, and a falling
    /// part must land on the entities of the parts under it.
    func dissolveAll() {
        waiting.removeAll()
        for (key, group) in groups {
            for id in group.members {
                groupOf.removeValue(forKey: id)
                releaseSlot(of: id)
            }
            group.members.removeAll()
            leaving.insert(key)
        }
    }

    /// Every part may be baked again from now (baking was switched back on).
    func wake<Parts: Sequence>(_ ids: Parts) where Parts.Element == UUID {
        let time = now
        for id in ids where groupOf[id] == nil && !pinned.contains(id) { waiting[id] = time }
    }

    /// The graphics setting changed the shapes: every mesh again, soon.
    func shapesChanged() {
        for key in groups.keys { joining.insert(key) }
    }

    func removeAll() {
        for group in groups.values { group.entity?.removeFromParent() }
        groups.removeAll()
        groupOf.removeAll()
        baked.removeAll()
        waiting.removeAll()
        timesTakenOut.removeAll()
        heldUntil.removeAll()
        pinned.removeAll()
        leaving.removeAll()
        joining.removeAll()
        palette = ColorPalette()
        paletteShown = -1
        paletteMaterials.removeAll()
        paletteFailed = false
        paletteTexture = nil
        paletteRepainted = false
        ownSlots.removeAll()
        freeSlots.removeAll()
        releasing.removeAll()
    }

    private func takeOut(_ id: UUID, hold: Bool) {
        guard let key = groupOf.removeValue(forKey: id), let group = groups[key] else { return }
        group.members.remove(id)
        releaseSlot(of: id)
        leaving.insert(key)
        if hold {
            let times = (timesTakenOut[id] ?? 0) + 1
            timesTakenOut[id] = times
            heldUntil[id] = now + Swift.min(120, 8 * pow(2, Double(times - 1)))
        }
    }

    /// A part's own spot may be given out again once no mesh draws it: when
    /// every mesh it left has been rebuilt.
    private func releaseSlot(of id: UUID) {
        if let slot = ownSlots.removeValue(forKey: id) { releasing.append(slot) }
    }

    // MARK: Every frame

    /// Puts waiting parts into meshes a few times a second and rebuilds a
    /// few meshes, within a slice of the frame.
    func update() {
        let time = now
        if !waiting.isEmpty, time - lastLook >= 0.25 {
            lastLook = time
            var due: [UUID] = []
            for (id, at) in waiting where at <= time { due.append(id) }
            for id in due {
                waiting.removeValue(forKey: id)
                join(id)
            }
            refreshPalette()
        }
        defer {
            if leaving.isEmpty, !releasing.isEmpty {
                freeSlots.append(contentsOf: releasing)
                releasing.removeAll()
            }
            if paletteRepainted { repaintPalette() }
        }
        guard !leaving.isEmpty || !joining.isEmpty else { return }
        let start = CACurrentMediaTime()
        // Parts leaving are seen to at once: until then they are drawn as
        // they were. Joining can wait for a quieter frame.
        while let key = leaving.first {
            leaving.remove(key)
            joining.remove(key)
            rebuild(key)
            if CACurrentMediaTime() - start > 0.010 { return }
        }
        var built = 0
        while let key = joining.first {
            joining.remove(key)
            rebuild(key)
            built += 1
            if built >= 1, CACurrentMediaTime() - start > 0.004 { return }
        }
    }

    private func join(_ id: UUID) {
        guard groupOf[id] == nil, !pinned.contains(id), let place = scene.bakingPlace(for: id),
              let block = scene.appliedBlock(id) else { return }
        let key: GroupKey
        let material: RealityKit.Material
        var paletteKind: MaterialKind?
        if !paletteFailed, RenderMerging.usesPalette(block, marked: BlockEntityFactory.isMarked(block)),
           palette.slot(for: block.color) != nil {
            // Any plain colour: one mesh per kind of material, its colours
            // read from the palette.
            key = GroupKey(place: place, material: AnyHashable("palette." + block.material.rawValue))
            if let made = paletteMaterials[block.material] {
                material = made
            } else {
                // The first of its kind: its material is made with the next
                // palette painting, before anything of it is drawn.
                material = SimpleMaterial()
                paletteShown = -1
            }
            paletteKind = block.material
        } else {
            let made = BlockEntityFactory.mergedMaterial(for: block)
            key = GroupKey(place: place, material: made.key)
            material = made.material
        }
        let group = groups[key] ?? {
            let group = Group(key: key, material: material, paletteKind: paletteKind)
            groups[key] = group
            return group
        }()
        group.members.insert(id)
        groupOf[id] = key
        joining.insert(key)
    }

    /// Builds the group's mesh from its members as they are now.
    private func rebuild(_ key: GroupKey) {
        guard let group = groups[key] else { return }
        var wanted: Set<UUID> = []
        var mesh: MeshResource?
        var bounds: BoundingBox?
        // One part is drawn as well on its own; a mesh is for many.
        if group.members.count >= 2 {
            var placements: [MeshGeometry.Placement] = []
            placements.reserveCapacity(group.members.count)
            for id in group.members {
                guard let block = scene.appliedBlock(id) else { continue }
                var spot: MeshGeometry.TexCoord?
                if group.paletteKind != nil {
                    // Its colour's spot; a colour new to the palette is
                    // painted into the texture before the mesh is shown.
                    guard let slot = ownSlots[id] ?? palette.slot(for: block.color) else { continue }
                    spot = ColorPalette.textureCoordinate(ofSlot: slot)
                }
                wanted.insert(id)
                placements.append(MeshGeometry.Placement(geometry: UnitShapes.geometry(for: block.shape, profile: scene.profile),
                                                         transform: block.transform,
                                                         textureRepeats: BlockEntityFactory.textureRepeats(for: block),
                                                         paletteCoordinate: spot))
                if case .patch = key.place {
                    let box = WorldDocument.bounds(of: block, at: block.transform)
                    bounds = bounds.map { BoundingBox(min: $0.min.componentMin(box.min), max: $0.max.componentMax(box.max)) } ?? box
                }
            }
            mesh = wanted.count >= 2 ? Self.makeMesh(placements) : nil
            if mesh == nil { wanted = [] }
            if group.paletteKind != nil {
                refreshPalette()
                if paletteFailed {
                    mesh = nil
                    wanted = []
                }
            }
        }

        if let mesh {
            if let entity = group.entity {
                entity.model?.mesh = mesh
            } else if let parent = scene.bakingParent(for: key.place) {
                let entity = ModelEntity(mesh: mesh, materials: [group.material])
                entity.name = "ablox.merged"
                parent.addChild(entity)
                group.entity = entity
            } else {
                wanted = []
            }
        }
        if wanted.isEmpty {
            group.entity?.removeFromParent()
            group.entity = nil
        }
        group.bounds = bounds
        if let entity = group.entity { entity.isEnabled = !group.isCulled }

        let before = group.drawn
        group.drawn = wanted
        for id in before where !wanted.contains(id) {
            baked.remove(id)
            scene.bakedStateChanged(id)
        }
        for id in wanted where !before.contains(id) {
            baked.insert(id)
            scene.bakedStateChanged(id)
        }
        if group.members.isEmpty, group.drawn.isEmpty {
            groups.removeValue(forKey: key)
        }
    }

    /// One mesh of many parts, in pieces small enough for the iPad.
    private static func makeMesh(_ placements: [MeshGeometry.Placement]) -> MeshResource? {
        var descriptors: [MeshDescriptor] = []
        var chunk: [MeshGeometry.Placement] = []
        var vertices = 0
        func flush() {
            guard !chunk.isEmpty else { return }
            let merged = MeshGeometry.merged(chunk)
            var descriptor = MeshDescriptor(name: "ablox.merged")
            descriptor.positions = MeshBuffers.Positions(merged.positions.map(\.simd))
            descriptor.normals = MeshBuffers.Normals(merged.normals.map(\.simd))
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(merged.textureCoordinates.map { SIMD2<Float>($0.u, $0.v) })
            descriptor.primitives = .triangles(merged.indices)
            descriptors.append(descriptor)
            chunk.removeAll(keepingCapacity: true)
            vertices = 0
        }
        for placement in placements {
            if vertices + placement.geometry.vertexCount > RenderMerging.maximumVertices { flush() }
            chunk.append(placement)
            vertices += placement.geometry.vertexCount
        }
        flush()
        guard !descriptors.isEmpty else { return nil }
        return try? MeshResource.generate(from: descriptors)
    }

    // MARK: The palette

    /// Paints the palette texture again when colours were added, and gives
    /// every palette mesh the new materials.
    private func refreshPalette() {
        guard !paletteFailed, palette.colors.count != paletteShown, !palette.colors.isEmpty else { return }
        guard let image = Self.paletteImage(palette),
              let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) else {
            // Never drawn with a stand-in material: those parts go back to a
            // mesh per colour.
            paletteFailed = true
            for (key, group) in groups where group.paletteKind != nil {
                for id in group.members {
                    groupOf.removeValue(forKey: id)
                    waiting[id] = now
                }
                group.members.removeAll()
                leaving.insert(key)
            }
            return
        }
        paletteShown = palette.colors.count
        paletteTexture = texture
        paletteRepainted = false
        let spots = MaterialParameters.Texture(texture, sampler: Self.paletteSampler())
        paletteMaterials.removeAll()
        for group in groups.values {
            guard let kind = group.paletteKind else { continue }
            let material = paletteMaterials[kind] ?? Self.paletteMaterial(kind, spots: spots)
            paletteMaterials[kind] = material
            group.material = material
            group.entity?.model?.materials = [material]
        }
    }

    /// Parts' own spots painted again: the texture's contents replaced in
    /// place, so every material made from it shows the new colours.
    private func repaintPalette() {
        paletteRepainted = false
        guard !paletteFailed else { return }
        guard palette.colors.count == paletteShown, let texture = paletteTexture, let image = Self.paletteImage(palette) else {
            // More colours as well: a new texture, with these in it.
            refreshPalette()
            return
        }
        do {
            try texture.replace(withImage: image, options: .init(semantic: .color))
        } catch {
            paletteShown = -1
            refreshPalette()
        }
    }

    /// The same material a part of this kind has on its own — the same
    /// roughness, the same metal, lit or not — its colour read from the
    /// palette instead of given as a tint.
    private static func paletteMaterial(_ kind: MaterialKind, spots: MaterialParameters.Texture) -> RealityKit.Material {
        if kind.isUnlit {
            var unlit = UnlitMaterial()
            unlit.color = .init(tint: .white, texture: spots)
            return unlit
        }
        var material = SimpleMaterial()
        material.color = .init(tint: .white, texture: spots)
        material.roughness = .init(floatLiteral: kind.roughness)
        material.metallic = .init(floatLiteral: kind.isMetallic ? 1.0 : 0.0)
        return material
    }

    /// Each spot exactly: no blending with the next, no smaller copies.
    private static func paletteSampler() -> MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    private static func paletteImage(_ palette: ColorPalette) -> CGImage? {
        let width = ColorPalette.width
        let bytes = palette.pixels()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Distance

    /// Hides the meshes beyond the view distance, as the parts in them
    /// would have been.
    func cull(from eye: Vec3, limit: Float, index: WorldIndex) {
        for group in groups.values {
            guard let entity = group.entity else { continue }
            let bounds: BoundingBox?
            switch group.key.place {
            case .patch:
                bounds = group.bounds
            case .model:
                // It moves with the block it hangs from.
                var union: BoundingBox?
                for id in group.drawn {
                    guard let box = index.bounds(of: id) else { continue }
                    union = union.map { BoundingBox(min: $0.min.componentMin(box.min), max: $0.max.componentMax(box.max)) } ?? box
                }
                bounds = union
            }
            guard let bounds else { continue }
            let far = bounds.distanceSquared(to: eye) > limit
            if far != group.isCulled {
                group.isCulled = far
                entity.isEnabled = !far
            }
        }
    }

    func showAll() {
        for group in groups.values where group.isCulled {
            group.isCulled = false
            group.entity?.isEnabled = true
        }
    }

    /// For the frame-rate counter: meshes drawn and parts in them.
    var summary: (meshes: Int, parts: Int) {
        (groups.values.filter { $0.entity != nil }.count, baked.count)
    }
}

/// The unit shapes the blocks are drawn with, as vertices to merge: the very
/// meshes a part on its own is drawn with, read back from RealityKit, so a
/// part looks the same in a merged mesh as out of one.
enum UnitShapes {

    private struct Key: Hashable {
        var shape: BlockShape
        var smooth: Bool
        var segments: Int
        var rings: Int
    }

    private static var cache: [Key: MeshGeometry] = [:]
    private static let lock = NSLock()

    /// No more vertices than this per part: a mesh read back with more is
    /// replaced by a plain one of the same shape.
    static let maximumVertices = 1_200

    static func geometry(for shape: BlockShape, profile: GraphicsProfile) -> MeshGeometry {
        let key = Key(shape: shape, smooth: profile.smoothShapes, segments: profile.roundSegments, rings: profile.sphereRings)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let made: MeshGeometry
        switch shape {
        // Built from these same vertices in the first place (ProceduralMesh).
        case .cylinder:
            made = .cylinder(height: 1, radius: 0.5, segments: profile.roundSegments)
        case .cone:
            made = .cone(height: 1, radius: 0.5, segments: profile.roundSegments)
        case .sphere where !profile.smoothShapes:
            made = .sphere(radius: 0.5, rings: profile.sphereRings, segments: profile.roundSegments)
        // RealityKit's own: read back what it made.
        case .box, .sphere, .plane:
            let fallback: MeshGeometry
            switch shape {
            case .box: fallback = .box()
            case .plane: fallback = .plane()
            default: fallback = .sphere(radius: 0.5, rings: profile.sphereRings, segments: profile.roundSegments)
            }
            made = readBack(BlockEntityFactory.mesh(for: shape, profile: profile), flat: shape == .plane) ?? fallback
        }

        lock.lock()
        cache[key] = made
        lock.unlock()
        return made
    }

    /// Vertices per part at a level, for the launch check's frame-rate run.
    static func describe(_ profile: GraphicsProfile) -> String {
        BlockShape.allCases.map { "\($0.rawValue)=\(geometry(for: $0, profile: profile).vertexCount)" }.joined(separator: " ")
    }

    /// The vertices of a unit mesh, or nil when they are not what a unit
    /// shape should be.
    private static func readBack(_ mesh: MeshResource, flat: Bool) -> MeshGeometry? {
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var textures: [MeshGeometry.TexCoord] = []
        var indices: [UInt32] = []
        for model in mesh.contents.models {
            for part in model.parts {
                let points = part.positions.elements
                guard let faces = part.triangleIndices?.elements, let ups = part.normals?.elements, ups.count == points.count else { return nil }
                let uvs = part.textureCoordinates?.elements ?? []
                let base = UInt32(positions.count)
                positions.append(contentsOf: points.map { Vec3($0) })
                normals.append(contentsOf: ups.map { Vec3($0) })
                if uvs.count == points.count {
                    textures.append(contentsOf: uvs.map { MeshGeometry.TexCoord(u: $0.x, v: $0.y) })
                } else {
                    textures.append(contentsOf: repeatElement(MeshGeometry.TexCoord(u: 0, v: 0), count: points.count))
                }
                indices.append(contentsOf: faces.map { base + $0 })
            }
        }
        guard !positions.isEmpty, positions.count <= maximumVertices, !indices.isEmpty, indices.count % 3 == 0,
              indices.allSatisfy({ Int($0) < positions.count }) else { return nil }
        // A unit shape: about a metre across, centred.
        var low = positions[0]
        var high = positions[0]
        for p in positions {
            low = low.componentMin(p)
            high = high.componentMax(p)
        }
        let size = high - low
        guard size.x > 0.9, size.x < 1.1, size.z > 0.9, size.z < 1.1, flat || (size.y > 0.9 && size.y < 1.1),
              (low + high).length < 0.1 else { return nil }
        return MeshGeometry(positions: positions, normals: normals, textureCoordinates: textures, indices: indices)
    }
}
