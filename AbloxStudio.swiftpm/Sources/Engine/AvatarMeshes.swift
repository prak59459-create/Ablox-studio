import Foundation
import RealityKit
import simd
import AbloxCore

/// The boxes and balls avatars are made of, built once per size and shared.
///
/// Every avatar is the same handful of rounded boxes. Building them afresh
/// for each one made a game that brings in a hundred NPCs at once (Last
/// Survivor Games) build hundreds of meshes in one frame, and the iPad froze.
/// Meshes are only read after they are made (`RigidParts` copies them), so
/// sharing one is safe.
enum AvatarMeshes {

    private struct Key: Hashable {
        var kind: Int
        var size: SIMD3<Float>
        var corner: Float
    }

    private static var cache: [Key: MeshResource] = [:]
    private static let lock = NSLock()

    static func box(_ size: SIMD3<Float>, corner: Float = 0) -> MeshResource {
        cached(Key(kind: 0, size: size, corner: corner)) {
            corner > 0 ? .generateBox(size: size, cornerRadius: corner) : .generateBox(size: size)
        }
    }

    static func ball(_ radius: Float) -> MeshResource {
        cached(Key(kind: 1, size: SIMD3<Float>(repeating: radius), corner: 0)) {
            .generateSphere(radius: radius)
        }
    }

    private static func cached(_ key: Key, _ make: () -> MeshResource) -> MeshResource {
        lock.lock()
        defer { lock.unlock() }
        if let mesh = cache[key] { return mesh }
        let mesh = make()
        cache[key] = mesh
        return mesh
    }
}
