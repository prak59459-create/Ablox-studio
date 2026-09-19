import Foundation
import RealityKit
import simd

/// Cylinders and cones that exist on iOS 17.
///
/// `MeshResource.generateCylinder(height:radius:)` and
/// `generateCone(height:radius:)` are iOS 18 API. Ablox ships to iOS 17, so
/// they do not compile — Swift Playgrounds on the iPad reported them the first
/// time the manifest was healthy enough to reach the source files.
///
/// `MeshResource.generate(from:)` has taken hand-built `MeshDescriptor`s since
/// iOS 15, so the shapes are built from vertices instead. The vertices come
/// from `MeshGeometry` in AbloxCore, where the winding and normals are
/// unit-tested; this file is only the hand-off to RealityKit.
///
/// There is deliberately no `if #available(iOS 18)` branch calling Apple's
/// version. One path means the geometry everyone sees is the geometry the
/// tests cover — a second path would only ever run on the iPads least likely
/// to be around to report a problem with it.
enum ProceduralMesh {

    /// How round the primitives are. Twenty-four segments is smooth at the
    /// size blocks are actually seen and costs 288 triangles a cylinder, which
    /// matters when a world has hundreds of them.
    static let defaultSegments = 24

    private struct Key: Hashable {
        enum Shape { case cylinder, cone }
        var shape: Shape
        var height: Float
        var radius: Float
        var segments: Int
    }

    // Same rationale as BlockEntityFactory's cache: a mesh is immutable and
    // shareable, and uploading one per hat or per block would be waste.
    private static var cache: [Key: MeshResource] = [:]
    private static let cacheLock = NSLock()

    static func cylinder(height: Float, radius: Float, segments: Int = defaultSegments) -> MeshResource {
        resource(
            for: Key(shape: .cylinder, height: height, radius: radius, segments: segments),
            name: "ablox.cylinder"
        )
    }

    static func cone(height: Float, radius: Float, segments: Int = defaultSegments) -> MeshResource {
        resource(
            for: Key(shape: .cone, height: height, radius: radius, segments: segments),
            name: "ablox.cone"
        )
    }

    private static func resource(for key: Key, name: String) -> MeshResource {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = cache[key] { return cached }

        let geometry: MeshGeometry
        switch key.shape {
        case .cylinder:
            geometry = .cylinder(height: key.height, radius: key.radius, segments: key.segments)
        case .cone:
            geometry = .cone(height: key.height, radius: key.radius, segments: key.segments)
        }

        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(geometry.positions.map(\.simd))
        descriptor.normals = MeshBuffers.Normals(geometry.normals.map(\.simd))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(
            geometry.textureCoordinates.map { SIMD2<Float>($0.u, $0.v) }
        )
        descriptor.primitives = .triangles(geometry.indices)

        // A box rather than a trap: if RealityKit ever refuses the descriptor,
        // the block is the wrong shape, which is visible and reportable. A
        // `try!` here would take the whole world down instead.
        let mesh = (try? MeshResource.generate(from: [descriptor]))
            ?? .generateBox(size: SIMD3<Float>(key.radius * 2, key.height, key.radius * 2))

        cache[key] = mesh
        return mesh
    }
}

extension MeshResource {
    /// iOS 17-safe stand-in for `generateCylinder(height:radius:)`.
    static func abloxCylinder(height: Float, radius: Float) -> MeshResource {
        ProceduralMesh.cylinder(height: height, radius: radius)
    }

    /// iOS 17-safe stand-in for `generateCone(height:radius:)`.
    static func abloxCone(height: Float, radius: Float) -> MeshResource {
        ProceduralMesh.cone(height: height, radius: radius)
    }
}
