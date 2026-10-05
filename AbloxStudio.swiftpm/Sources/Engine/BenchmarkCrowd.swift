import Foundation
import RealityKit
import UIKit
import simd
import AbloxCore

/// Players for the launch check's frame-rate run (`-AbloxPlayBenchmark YES`):
/// a room's worth of avatars in every kind of hat, face, pet and ride, so the
/// run draws what a full game draws. Nobody meets them in the app.
@MainActor
enum BenchmarkCrowd {

    /// Eight players standing round the spawn, each dressed differently.
    static func dress(around spawn: Vec3, into parent: Entity) -> [AvatarEntity] {
        let hats = AvatarProfile.HatStyle.allCases.filter { $0 != .none }
        let faces = AvatarProfile.Face.allCases
        let pets = AvatarProfile.Pet.allCases.filter { $0 != .none }
        let rides = AvatarProfile.Ride.allCases
        let colours = ["#F97316", "#22D3EE", "#F472B6", "#A3E635", "#FDE047", "#818CF8", "#F87171", "#34D399"]
        var crowd: [AvatarEntity] = []
        for i in 0..<8 {
            let profile = AvatarProfile(
                displayName: "Player \(i + 1)",
                bodyColor: ColorRGBA(hex: colours[i]) ?? ColorRGBA(r: 1, g: 1, b: 1),
                hat: hats[(i * 5) % hats.count],
                ride: rides[i % rides.count],
                face: faces[(i * 3) % faces.count],
                pet: pets[(i * 2) % pets.count]
            )
            let angle = Float(i) / 8 * 2 * .pi
            let at = spawn + Vec3(cos(angle) * 6, 0, sin(angle) * 6 - 4)
            let avatar = AvatarEntity(peerID: PeerID(), profile: profile, position: at)
            parent.addChild(avatar)
            crowd.append(avatar)
        }
        return crowd
    }

    /// The parts the GPU is handed for `entity` and everything under it.
    static func drawnParts(_ entity: Entity) -> Int {
        var count = (entity as? ModelEntity)?.model != nil && entity.isEnabled ? 1 : 0
        for child in entity.children { count += drawnParts(child) }
        return count
    }

    /// Every hat, face and pet built twice, once with its parts merged
    /// (`RigidParts`): the parts each is drawn as, and the most their
    /// outlines differ by — nothing, if the merged parts are where they were.
    /// The outline is measured from every vertex, placed by RealityKit's own
    /// `convert`, not by the matrices the merging uses.
    static func checkMergedPieces() -> String {
        let main = AvatarWardrobe.material(red: 0.9, green: 0.3, blue: 0.3)
        var pieces: [(Entity, Entity, String?)] = []
        for hat in AvatarProfile.HatStyle.allCases {
            if let plain = AvatarWardrobe.hat(hat, main: main), let merged = AvatarWardrobe.hat(hat, main: main) {
                pieces.append((plain, merged, AvatarWardrobe.spinningPart))
            }
        }
        for face in AvatarProfile.Face.allCases {
            if let plain = AvatarWardrobe.face(face), let merged = AvatarWardrobe.face(face) { pieces.append((plain, merged, nil)) }
        }
        for pet in AvatarProfile.Pet.allCases {
            if let plain = AvatarWardrobe.pet(pet, skin: main), let merged = AvatarWardrobe.pet(pet, skin: main) {
                pieces.append((plain, merged, nil))
            }
        }
        var before = 0
        var after = 0
        var furthest: Float = 0
        for (plain, merged, keeping) in pieces {
            RigidParts.merge(merged, keeping: keeping)
            before += drawnParts(plain)
            after += drawnParts(merged)
            guard let a = outline(of: plain), let b = outline(of: merged) else { continue }
            furthest = max(furthest, simd_length(a.low - b.low), simd_length(a.high - b.high))
        }
        return String(format: "%d hats, faces and pets: %d parts drawn as %d, outlines differ by %.4f m at most",
                      pieces.count, before, after, furthest)
    }

    /// The box round every vertex under `root`, in its space.
    private static func outline(of root: Entity) -> (low: SIMD3<Float>, high: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        func visit(_ entity: Entity) {
            if let part = entity as? ModelEntity, let mesh = part.model?.mesh {
                for model in mesh.contents.models {
                    for piece in model.parts {
                        for point in piece.positions.elements {
                            let placed = root.convert(position: point, from: part)
                            low = simd_min(low, placed)
                            high = simd_max(high, placed)
                        }
                    }
                }
            }
            for child in entity.children { visit(child) }
        }
        for child in root.children { visit(child) }
        return low.x.isFinite ? (low, high) : nil
    }
}
