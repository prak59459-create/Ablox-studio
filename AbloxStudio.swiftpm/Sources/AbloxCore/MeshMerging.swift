import Foundation

// Many blocks drawn as one.
//
// RealityKit draws every entity separately, and each one costs the iPad time
// on the CPU (and once more for the sun's shadows) whatever its size. A
// catalogue world has a thousand parts that never move and a character game
// hundreds of characters of eighteen parts each, so most of a frame went on
// the number of things drawn rather than on what they looked like. Blocks
// that stay put are baked into one mesh per colour and material — a patch of
// the map, or a character's parts under its root — and drawn as a handful.
//
// The geometry is worked out here, where it is tested on Linux; the renderer
// only hands the result to RealityKit.

extension MeshGeometry {

    /// A unit cube centred on the origin: four vertices a face, so each face
    /// has its own normal and its texture runs 0…1 across it, as RealityKit's
    /// own box does.
    public static func box() -> MeshGeometry {
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var textures: [TexCoord] = []
        var indices: [UInt32] = []
        // Each face: its normal, and two directions across it (u then v)
        // whose cross product is the normal, so the winding faces out.
        let faces: [(normal: Vec3, u: Vec3, v: Vec3)] = [
            (Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)),
            (Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)),
            (Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, -1)),
            (Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)),
            (Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)),
            (Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0))
        ]
        for face in faces {
            let base = UInt32(positions.count)
            let centre = face.normal * 0.5
            for (du, dv) in [(Float(-0.5), Float(-0.5)), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)] {
                positions.append(centre + face.u * du + face.v * dv)
                normals.append(face.normal)
                textures.append(TexCoord(u: du + 0.5, v: dv + 0.5))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return MeshGeometry(positions: positions, normals: normals, textureCoordinates: textures, indices: indices)
    }

    /// A unit square in the XZ plane facing up, as RealityKit's plane.
    public static func plane() -> MeshGeometry {
        MeshGeometry(
            positions: [Vec3(-0.5, 0, 0.5), Vec3(0.5, 0, 0.5), Vec3(0.5, 0, -0.5), Vec3(-0.5, 0, -0.5)],
            normals: Array(repeating: Vec3(0, 1, 0), count: 4),
            textureCoordinates: [TexCoord(u: 0, v: 0), TexCoord(u: 1, v: 0), TexCoord(u: 1, v: 1), TexCoord(u: 0, v: 1)],
            indices: [0, 1, 2, 0, 2, 3]
        )
    }

    /// One piece of a merged mesh: a unit shape where a block puts it.
    public struct Placement: Sendable {
        public var geometry: MeshGeometry
        /// Position, turn and size, in the space the merged mesh is drawn in.
        public var transform: Transform3D
        /// How many times a pattern repeats across it: the material of a
        /// merged mesh repeats once, so each block's own count is baked in.
        public var textureRepeats: Float

        public init(geometry: MeshGeometry, transform: Transform3D, textureRepeats: Float = 1) {
            self.geometry = geometry
            self.transform = transform
            self.textureRepeats = textureRepeats
        }
    }

    /// Every placement baked into one mesh, in order.
    ///
    /// Positions are scaled, turned and moved; normals are turned and divided
    /// by the scale before being made unit length again, which keeps them
    /// square to the surface of a stretched block.
    public static func merged(_ placements: [Placement]) -> MeshGeometry {
        var positions: [Vec3] = []
        var normals: [Vec3] = []
        var textures: [TexCoord] = []
        var indices: [UInt32] = []
        let vertexTotal = placements.reduce(0) { $0 + $1.geometry.vertexCount }
        positions.reserveCapacity(vertexTotal)
        normals.reserveCapacity(vertexTotal)
        textures.reserveCapacity(vertexTotal)
        indices.reserveCapacity(placements.reduce(0) { $0 + $1.geometry.indices.count })

        for placement in placements {
            let t = placement.transform
            let base = UInt32(positions.count)
            let scale = t.scale
            let inverse = Vec3(scale.x == 0 ? 0 : 1 / scale.x, scale.y == 0 ? 0 : 1 / scale.y, scale.z == 0 ? 0 : 1 / scale.z)
            // A mirrored block (an odd number of negative sizes) would face
            // its triangles inward; their order is swapped to face out again.
            let mirrored = scale.x * scale.y * scale.z < 0
            let geometry = placement.geometry
            for p in geometry.positions {
                positions.append(t.rotation.act(p * scale) + t.position)
            }
            for n in geometry.normals {
                let turned = t.rotation.act(n * inverse)
                let length = turned.length
                normals.append(length > 1e-6 ? turned * (1 / length) : n)
            }
            let repeats = placement.textureRepeats
            for c in geometry.textureCoordinates {
                textures.append(TexCoord(u: c.u * repeats, v: c.v * repeats))
            }
            var i = 0
            let source = geometry.indices
            while i + 2 < source.count {
                if mirrored {
                    indices.append(contentsOf: [base + source[i], base + source[i + 2], base + source[i + 1]])
                } else {
                    indices.append(contentsOf: [base + source[i], base + source[i + 1], base + source[i + 2]])
                }
                i += 3
            }
        }
        return MeshGeometry(positions: positions, normals: normals, textureCoordinates: textures, indices: indices)
    }
}

/// Which blocks can be drawn as part of a merged mesh, and where they go.
public enum RenderMerging {

    /// The side of a patch of map merged into one mesh, in metres. Big enough
    /// that a world is a few dozen patches, small enough that the ones out of
    /// view are not drawn.
    public static let patchSize: Float = 48

    /// No more vertices than this in one mesh; a bigger group is split.
    public static let maximumVertices = 60_000

    /// Whether a block can be baked into a merged mesh: drawn as it stands,
    /// solid-looking, with nothing hanging from it and nothing about it the
    /// renderer moves or swaps by itself. Anything a script changes later is
    /// taken out of the mesh again then.
    public static func canMerge(_ block: BlockData, hasChildren: Bool) -> Bool {
        // Not anchored: physics can knock it over, so it moves by itself.
        guard !hasChildren, block.isVisible, block.isAnchored else { return false }
        guard block.color.a * block.material.alphaScale >= 0.999 else { return false }
        guard block.imageID == nil, block.light == nil, block.animation == nil else { return false }
        if let label = block.label, !label.isEmpty { return false }
        switch block.behavior {
        // Moved, opened or ridden by the renderer itself, or made to vanish
        // when touched: taking one out of a mesh means drawing the mesh again.
        case .elevator, .door, .vehicle, .pushable, .collectible, .disappear:
            return false
        default:
            break
        }
        return true
    }

    /// Whether two versions of a block are drawn alike and bake alike: a
    /// script renaming, retagging or scoring a block leaves it in its mesh.
    public static func looksTheSame(_ a: BlockData, _ b: BlockData) -> Bool {
        a.id == b.id && a.transform == b.transform && a.color == b.color && a.parentID == b.parentID
            && a.isVisible == b.isVisible && a.isAnchored == b.isAnchored && a.shape == b.shape && a.material == b.material
            && a.behavior == b.behavior && a.imageID == b.imageID && a.light == b.light && a.label == b.label
            && a.animation == b.animation
    }

    /// Whether a block draws nothing at all: see-through to the end, like the
    /// root a character's parts hang from. Such a block keeps its place in
    /// the scene but is not handed to the GPU.
    public static func drawsNothing(_ block: BlockData) -> Bool {
        block.color.a * block.material.alphaScale < 0.004
    }

    /// The patch of map a point is in.
    public struct Patch: Hashable, Sendable {
        public var x: Int32
        public var z: Int32

        public init(x: Int32, z: Int32) {
            self.x = x
            self.z = z
        }
    }

    public static func patch(containing point: Vec3) -> Patch {
        func cell(_ value: Float) -> Int32 {
            guard value.isFinite else { return 0 }
            let scaled = (value / patchSize).rounded(.down)
            return Int32(Swift.max(-100_000, Swift.min(100_000, scaled)))
        }
        return Patch(x: cell(point.x), z: cell(point.z))
    }
}
