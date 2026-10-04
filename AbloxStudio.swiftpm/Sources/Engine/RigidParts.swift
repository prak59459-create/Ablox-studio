import Foundation
import RealityKit
import UIKit
import simd

/// Draws the parts of something that only ever moves as a whole — a face, a
/// hat, a pet, a car — as one mesh per material instead of one per part.
///
/// A car of eleven boxes and wheels was eleven things for the iPad to draw
/// (twice, with its shadow) for every player in the room; it is five: the
/// paint, the glass, the tyres and trim, the lamps and the brake lights. The
/// vertices are the parts' own meshes, read back and placed where the parts
/// were, and each mesh keeps the very material its parts had, so it looks the
/// same.
enum RigidParts {

    /// Merges the leaf parts under `root` that share a plain material (a
    /// colour, its roughness and metal, lit or not), leaving everything else
    /// as it was: a part named `keeping` and what hangs from it (a propeller
    /// that turns by itself), a part of more than one material, a textured
    /// or see-through one, a part that is switched off. Returns how many
    /// parts were taken away.
    @discardableResult
    static func merge(_ root: Entity, keeping: String? = nil) -> Int {
        var groups: [String: (material: RealityKit.Material, parts: [ModelEntity])] = [:]
        var order: [String] = []
        collect(root, under: root, keeping: keeping, into: &groups, order: &order)

        var removed = 0
        for key in order {
            guard let group = groups[key], group.parts.count >= 2 else { continue }
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var textures: [SIMD2<Float>] = []
            var indices: [UInt32] = []
            var merged: [ModelEntity] = []
            for part in group.parts {
                guard let mesh = part.model?.mesh,
                      append(mesh, placed: part.transformMatrix(relativeTo: root),
                             positions: &positions, normals: &normals, textures: &textures, indices: &indices) else { continue }
                merged.append(part)
            }
            guard merged.count >= 2, positions.count <= 60_000 else { continue }
            var descriptor = MeshDescriptor(name: "ablox.parts")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            if textures.count == positions.count {
                descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(textures)
            }
            descriptor.primitives = .triangles(indices)
            guard let resource = try? MeshResource.generate(from: [descriptor]) else { continue }
            let entity = ModelEntity(mesh: resource, materials: [group.material])
            entity.name = "ablox.parts"
            root.addChild(entity)
            for part in merged { part.removeFromParent() }
            removed += merged.count - 1
        }
        return removed
    }

    private static func collect(_ entity: Entity, under root: Entity, keeping: String?,
                                into groups: inout [String: (material: RealityKit.Material, parts: [ModelEntity])],
                                order: inout [String]) {
        for child in entity.children {
            if let keeping, child.name == keeping { continue }
            guard child.children.isEmpty else {
                collect(child, under: root, keeping: keeping, into: &groups, order: &order)
                continue
            }
            guard let part = child as? ModelEntity, part.isEnabled, let model = part.model,
                  model.materials.count == 1, let key = key(for: model.materials[0]) else { continue }
            if groups[key] == nil {
                groups[key] = (model.materials[0], [])
                order.append(key)
            }
            groups[key]?.parts.append(part)
        }
    }

    /// What makes two materials draw alike, or nil for one this cannot tell
    /// (a picture on it, see-through, another kind of material).
    private static func key(for material: RealityKit.Material) -> String? {
        if let lit = material as? SimpleMaterial {
            guard lit.color.texture == nil, let colour = components(lit.color.tint),
                  case let .float(roughness) = lit.roughness, case let .float(metallic) = lit.metallic else { return nil }
            return "lit \(colour) \(roughness) \(metallic)"
        }
        if let unlit = material as? UnlitMaterial {
            guard unlit.color.texture == nil, case .opaque = unlit.blending, let colour = components(unlit.color.tint) else { return nil }
            return "unlit \(colour)"
        }
        return nil
    }

    /// The colour as exact numbers, if it is solid.
    private static func components(_ colour: UIColor) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha), alpha >= 0.999 else { return nil }
        return "\(red) \(green) \(blue)"
    }

    /// Adds a part's mesh, placed by `placed`, or says it could not.
    private static func append(_ mesh: MeshResource, placed: simd_float4x4, positions: inout [SIMD3<Float>],
                               normals: inout [SIMD3<Float>], textures: inout [SIMD2<Float>], indices: inout [UInt32]) -> Bool {
        // Meshes made in code have one copy of each model, where it was made.
        for instance in mesh.contents.instances where instance.transform != matrix_identity_float4x4 { return false }
        let turn = simd_float3x3(SIMD3<Float>(placed.columns.0.x, placed.columns.0.y, placed.columns.0.z),
                                 SIMD3<Float>(placed.columns.1.x, placed.columns.1.y, placed.columns.1.z),
                                 SIMD3<Float>(placed.columns.2.x, placed.columns.2.y, placed.columns.2.z))
        let determinant = simd_determinant(turn)
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return false }
        let normalTurn = turn.inverse.transpose
        // A mirrored part's triangles face the other way round.
        let mirrored = determinant < 0

        var newPositions: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var newTextures: [SIMD2<Float>] = []
        var newIndices: [UInt32] = []
        var textured = true
        for model in mesh.contents.models {
            for part in model.parts {
                let points = part.positions.elements
                guard let faces = part.triangleIndices?.elements, let ups = part.normals?.elements,
                      ups.count == points.count, faces.count % 3 == 0 else { return false }
                let base = UInt32(positions.count + newPositions.count)
                for point in points {
                    let moved = placed * SIMD4<Float>(point, 1)
                    newPositions.append(SIMD3<Float>(moved.x, moved.y, moved.z))
                }
                for up in ups {
                    let turned = normalTurn * up
                    let length = simd_length(turned)
                    newNormals.append(length > 1e-6 ? turned / length : up)
                }
                if let uvs = part.textureCoordinates?.elements, uvs.count == points.count {
                    newTextures.append(contentsOf: uvs)
                } else {
                    textured = false
                }
                var i = 0
                while i + 2 < faces.count {
                    guard Int(faces[i]) < points.count, Int(faces[i + 1]) < points.count, Int(faces[i + 2]) < points.count else {
                        return false
                    }
                    if mirrored {
                        newIndices.append(contentsOf: [base + faces[i], base + faces[i + 2], base + faces[i + 1]])
                    } else {
                        newIndices.append(contentsOf: [base + faces[i], base + faces[i + 1], base + faces[i + 2]])
                    }
                    i += 3
                }
            }
        }
        guard !newPositions.isEmpty else { return false }
        positions.append(contentsOf: newPositions)
        normals.append(contentsOf: newNormals)
        if textured, textures.count == positions.count - newPositions.count {
            textures.append(contentsOf: newTextures)
        } else {
            // One part without texture coordinates: the mesh has none.
            textures.removeAll()
        }
        indices.append(contentsOf: newIndices)
        return true
    }
}
