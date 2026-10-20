import Foundation
import RealityKit
import simd
import UIKit
import AbloxCore

/// The small parts that make the blocky avatar read as a person up close:
/// a neck, ears, short sleeves, hands, a belt with a buckle, shirt buttons,
/// a pocket, knees, shoes with soles and laces.
///
/// Each part hangs off the limb it belongs to, so the poses move it with the
/// limb, and the parts on one limb are merged into one mesh per colour
/// (`RigidParts`), so a room full of avatars is only a few more things to
/// draw. The lowest two graphics levels leave them off (`detailed`).
extension AvatarEntity {

    static let detailName = "ablox.avatar.detail"

    /// Builds the parts again for `profile`'s colours, or takes them away.
    func applyDetail(_ profile: AvatarProfile) {
        for limb in [body, head, leftArm, rightArm, leftLeg, rightLeg] {
            let old = limb.children.filter { $0.name == Self.detailName }
            for child in old { child.removeFromParent() }
        }
        guard detailed else { return }

        let skin = detailMaterial(profile.headColor)
        let shirt = detailMaterial(profile.bodyColor)
        let trousers = detailMaterial(profile.accentColor)
        let shirtShade = detailMaterial(profile.bodyColor.shaded(0.8))
        let trouserShade = detailMaterial(profile.accentColor.shaded(0.85))
        let skinShade = detailMaterial(profile.headColor.shaded(0.9))
        let shoe = AvatarWardrobe.dark
        let sole = AvatarWardrobe.white
        let gold = AvatarWardrobe.gold

        // The body: 0.6 × 0.7 × 0.34, its middle at the rig's 0.95.
        attach(to: body) { group in
            add(group, skin, size: [0.26, 0.08, 0.22], at: [0, 0.38, 0])                 // neck
            add(group, shirtShade, size: [0.3, 0.04, 0.05], at: [0, 0.33, -0.16])        // collar
            add(group, trouserShade, size: [0.62, 0.08, 0.36], at: [0, -0.31, 0])        // belt
            add(group, gold, size: [0.1, 0.07, 0.02], at: [0, -0.31, -0.18])             // buckle
            for y: Float in [0.2, 0.05, -0.1] {
                add(group, shirtShade, size: [0.045, 0.045, 0.02], at: [0, y, -0.175])   // buttons
            }
            add(group, shirtShade, size: [0.13, 0.12, 0.02], at: [-0.16, 0.14, -0.175])  // pocket
            add(group, shirtShade, size: [0.62, 0.03, 0.36], at: [0, -0.26, 0])          // hem
        }

        // The head: 0.45 on a side.
        attach(to: head) { group in
            for side: Float in [-1, 1] {
                add(group, skin, size: [0.05, 0.12, 0.1], at: [side * 0.245, 0.0, 0.02])  // ears
                add(group, skinShade, size: [0.02, 0.06, 0.05], at: [side * 0.27, 0.0, 0.02])
            }
            add(group, skinShade, size: [0.06, 0.07, 0.03], at: [0, -0.02, -0.235])      // nose
        }

        // The arms: 0.24 × 0.6 × 0.26, the shoulder at the top.
        for arm in [leftArm, rightArm] {
            attach(to: arm) { group in
                add(group, shirt, size: [0.26, 0.24, 0.28], at: [0, 0.19, 0])            // sleeve
                add(group, shirtShade, size: [0.27, 0.03, 0.29], at: [0, 0.07, 0])       // its hem
                add(group, skinShade, size: [0.22, 0.13, 0.24], at: [0, -0.34, 0])       // hand
                add(group, skinShade, size: [0.06, 0.06, 0.08], at: [0, -0.3, -0.13])    // thumb
            }
        }

        // The legs: 0.29 × 0.6 × 0.3, the hip at the top, feet on the ground.
        for leg in [leftLeg, rightLeg] {
            attach(to: leg) { group in
                add(group, trouserShade, size: [0.3, 0.06, 0.02], at: [0, 0.0, -0.155])  // knee
                add(group, shoe, size: [0.31, 0.12, 0.38], at: [0, -0.23, -0.04])        // shoe
                add(group, sole, size: [0.32, 0.035, 0.39], at: [0, -0.29, -0.04])       // sole
                add(group, sole, size: [0.12, 0.02, 0.02], at: [0, -0.2, -0.235])        // laces
                add(group, sole, size: [0.12, 0.02, 0.02], at: [0, -0.24, -0.235])
                add(group, trouserShade, size: [0.3, 0.04, 0.31], at: [0, -0.15, 0])     // cuff
            }
        }
    }

    private func attach(to limb: ModelEntity, _ build: (Entity) -> Void) {
        let group = Entity()
        group.name = Self.detailName
        build(group)
        RigidParts.merge(group)
        limb.addChild(group)
    }

    private func add(_ group: Entity, _ material: RealityKit.Material, size: SIMD3<Float>, at position: SIMD3<Float>) {
        let part = ModelEntity(mesh: AvatarMeshes.box(size, corner: Swift.min(size.x, size.y, size.z) * 0.2),
                               materials: [material])
        part.position = position
        group.addChild(part)
    }

    private func detailMaterial(_ color: ColorRGBA) -> RealityKit.Material {
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1))
        material.roughness = .init(floatLiteral: 0.6)
        material.metallic = .init(floatLiteral: 0.0)
        return material
    }
}

private extension ColorRGBA {
    /// The same colour, darker by `factor` (a crease, a seam, a shadowed part).
    func shaded(_ factor: Float) -> ColorRGBA {
        ColorRGBA(r: r * factor, g: g * factor, b: b * factor, a: a)
    }
}
