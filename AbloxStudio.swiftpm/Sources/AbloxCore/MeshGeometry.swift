import Foundation

/// Triangle geometry, built without any Apple framework.
///
/// ## Why this exists
///
/// `MeshResource.generateCylinder(height:radius:)` and `generateCone(_:)` are
/// iOS 18 API. Ablox deploys to iOS 17, so calling them does not compile —
/// which is how they were found, on an iPad, after the manifest started
/// working.
///
/// The two honest ways out were raising the deployment target or building the
/// meshes here. Raising it would drop every iPad that stopped at iPadOS 17,
/// and a cylinder is a hundred lines of trigonometry, so this builds them.
///
/// The second reason to put them here rather than in `Engine/` is that this
/// module compiles on Linux. Vertex winding, normal direction and index bounds
/// are exactly the kind of thing that is invisible on screen until a face
/// turns inside out, and here they can be asserted in a test instead.
///
/// Conventions match RealityKit's own primitives so these are drop-in:
/// - the shape is centred on the origin and its axis is +Y,
/// - `height` is the full extent, `radius` is the outer radius,
/// - triangles wind counter-clockwise seen from outside, so their right-hand
///   normal points away from the surface.
public struct MeshGeometry: Equatable, Sendable {

    public struct TexCoord: Equatable, Sendable {
        public var u: Float
        public var v: Float

        public init(u: Float, v: Float) {
            self.u = u
            self.v = v
        }
    }

    public private(set) var positions: [Vec3]
    public private(set) var normals: [Vec3]
    public private(set) var textureCoordinates: [TexCoord]
    public private(set) var indices: [UInt32]

    public init(
        positions: [Vec3],
        normals: [Vec3],
        textureCoordinates: [TexCoord],
        indices: [UInt32]
    ) {
        self.positions = positions
        self.normals = normals
        self.textureCoordinates = textureCoordinates
        self.indices = indices
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }

    /// The axis-aligned box the vertices occupy.
    public var bounds: BoundingBox {
        guard let first = positions.first else {
            return BoundingBox(min: .zero, max: .zero)
        }
        var lo = first
        var hi = first
        for p in positions.dropFirst() {
            lo = lo.componentMin(p)
            hi = hi.componentMax(p)
        }
        return BoundingBox(min: lo, max: hi)
    }

    /// The right-hand normal of a triangle, which points out of the surface
    /// when the winding is correct. Not normalised — callers compare direction.
    public func faceNormal(ofTriangle triangle: Int) -> Vec3 {
        let i = triangle * 3
        let a = positions[Int(indices[i])]
        let b = positions[Int(indices[i + 1])]
        let c = positions[Int(indices[i + 2])]
        return (b - a).cross(c - a)
    }

    /// Every buffer the same length, every index in range, a whole number of
    /// triangles, and no triangle that names the same vertex twice.
    ///
    /// RealityKit's reaction to a malformed descriptor ranges from a thrown
    /// error to a blank screen, so this is checked here where the answer is
    /// unambiguous.
    public var isWellFormed: Bool {
        guard !positions.isEmpty,
              normals.count == positions.count,
              textureCoordinates.count == positions.count,
              indices.count % 3 == 0,
              !indices.isEmpty
        else { return false }

        let limit = UInt32(positions.count)
        for index in indices where index >= limit { return false }

        for triangle in 0..<triangleCount {
            let i = triangle * 3
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            if a == b || b == c || a == c { return false }
        }
        return true
    }

    // MARK: - Primitives

    /// A closed cylinder: a tube plus a cap at each end.
    ///
    /// The tube's ring carries a duplicate vertex at the seam. Sharing one
    /// vertex there would be fine for position and normal but wrong for the
    /// texture coordinate, which has to read 0 on one side and 1 on the other.
    public static func cylinder(height: Float, radius: Float, segments: Int = 24) -> MeshGeometry {
        var builder = Builder()
        let segments = Swift.max(3, segments)
        let halfHeight = height / 2

        // --- Side ---------------------------------------------------------
        // Normals are radial rather than per-face, so the tube shades as a
        // curve instead of a prism.
        let sideBase = builder.vertexCount
        for step in 0...segments {
            let t = Float(step) / Float(segments)
            let angle = t * 2 * Float.pi
            let outward = Vec3(cos(angle), 0, sin(angle))
            let ring = outward * radius

            builder.addVertex(
                position: Vec3(ring.x, -halfHeight, ring.z),
                normal: outward,
                texture: TexCoord(u: t, v: 0)
            )
            builder.addVertex(
                position: Vec3(ring.x, halfHeight, ring.z),
                normal: outward,
                texture: TexCoord(u: t, v: 1)
            )
        }

        for step in 0..<segments {
            let bottom = UInt32(sideBase + step * 2)
            let top = bottom + 1
            let nextBottom = bottom + 2
            let nextTop = bottom + 3
            // Winding checked in MeshGeometryTests: these two orders are what
            // make the right-hand normal point away from the axis.
            builder.addTriangle(bottom, top, nextBottom)
            builder.addTriangle(nextBottom, top, nextTop)
        }

        builder.addCap(y: halfHeight, radius: radius, segments: segments, facingUp: true)
        builder.addCap(y: -halfHeight, radius: radius, segments: segments, facingUp: false)

        return builder.geometry
    }

    /// A cone: a skirt from the base ring up to the apex, plus a base cap.
    ///
    /// Each side triangle gets its own apex vertex. A cone's apex has no single
    /// normal — it is a different direction for every segment meeting there —
    /// so sharing one vertex would light the tip as if it were flat.
    public static func cone(height: Float, radius: Float, segments: Int = 24) -> MeshGeometry {
        var builder = Builder()
        let segments = Swift.max(3, segments)
        let halfHeight = height / 2

        // The surface leans, so its normal does too: perpendicular to the
        // slant, which tilts by the ratio of radius to height rather than
        // pointing straight out.
        func slantNormal(atAngle angle: Float) -> Vec3 {
            Vec3(height * cos(angle), radius, height * sin(angle)).normalized
        }

        let ringBase = builder.vertexCount
        for step in 0...segments {
            let t = Float(step) / Float(segments)
            let angle = t * 2 * Float.pi
            builder.addVertex(
                position: Vec3(cos(angle) * radius, -halfHeight, sin(angle) * radius),
                normal: slantNormal(atAngle: angle),
                texture: TexCoord(u: t, v: 0)
            )
        }

        for step in 0..<segments {
            let t = (Float(step) + 0.5) / Float(segments)
            // The apex normal is taken at the middle of the segment it caps,
            // which is the direction the triangle actually faces.
            builder.addVertex(
                position: Vec3(0, halfHeight, 0),
                normal: slantNormal(atAngle: t * 2 * Float.pi),
                texture: TexCoord(u: t, v: 1)
            )
            let apex = UInt32(builder.vertexCount - 1)
            let base = UInt32(ringBase + step)
            builder.addTriangle(base, apex, base + 1)
        }

        builder.addCap(y: -halfHeight, radius: radius, segments: segments, facingUp: false)

        return builder.geometry
    }

    // MARK: - Builder

    private struct Builder {
        private var positions: [Vec3] = []
        private var normals: [Vec3] = []
        private var textures: [TexCoord] = []
        private var indices: [UInt32] = []

        var vertexCount: Int { positions.count }

        var geometry: MeshGeometry {
            MeshGeometry(
                positions: positions,
                normals: normals,
                textureCoordinates: textures,
                indices: indices
            )
        }

        mutating func addVertex(position: Vec3, normal: Vec3, texture: TexCoord) {
            positions.append(position)
            normals.append(normal)
            textures.append(texture)
        }

        mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
            indices.append(contentsOf: [a, b, c])
        }

        /// A disc in the XZ plane: a centre vertex fanned out to a ring.
        ///
        /// The ring is built here rather than shared with the side, because a
        /// cap vertex faces along Y while the side vertex at the same point
        /// faces outward — one position, two normals, so two vertices.
        mutating func addCap(y: Float, radius: Float, segments: Int, facingUp: Bool) {
            let normal = Vec3(0, facingUp ? 1 : -1, 0)

            let centre = UInt32(positions.count)
            addVertex(position: Vec3(0, y, 0), normal: normal, texture: TexCoord(u: 0.5, v: 0.5))

            let ringBase = UInt32(positions.count)
            for step in 0...segments {
                let angle = Float(step) / Float(segments) * 2 * Float.pi
                let x = cos(angle)
                let z = sin(angle)
                addVertex(
                    position: Vec3(x * radius, y, z * radius),
                    normal: normal,
                    texture: TexCoord(u: 0.5 + 0.5 * x, v: 0.5 + 0.5 * z)
                )
            }

            for step in 0..<segments {
                let a = ringBase + UInt32(step)
                let b = a + 1
                // Reversed for the top, so both discs wind away from the solid
                // rather than both winding the same way in world space.
                if facingUp {
                    addTriangle(centre, b, a)
                } else {
                    addTriangle(centre, a, b)
                }
            }
        }
    }
}
