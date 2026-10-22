import Foundation
import RealityKit
import UIKit
import AbloxCore

/// Weapons built from boxes, like avatars: no asset files, and a new model is
/// a few lines rather than a download.
///
/// Every model points down -Z with its grip at the origin, so the same entity
/// can sit in an avatar's hand or at the bottom corner of a first-person view.
enum WeaponModel {

    /// The weapon for a `WeaponSpec.model` name. Unknown names get a blaster,
    /// the same fallback the host uses.
    static func make(_ model: String) -> Entity {
        let root = Entity()
        root.name = "ablox.weapon.\(model)"

        let metal = SimpleMaterial(color: UIColor(white: 0.16, alpha: 1), roughness: 0.35, isMetallic: true)
        let body = SimpleMaterial(color: UIColor(white: 0.32, alpha: 1), roughness: 0.6, isMetallic: false)
        let accent = SimpleMaterial(color: UIColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1), roughness: 0.3, isMetallic: false)
        let wood = SimpleMaterial(color: UIColor(red: 0.55, green: 0.36, blue: 0.2, alpha: 1), roughness: 0.8, isMetallic: false)
        let blade = SimpleMaterial(color: UIColor(white: 0.82, alpha: 1), roughness: 0.25, isMetallic: true)
        let glove = SimpleMaterial(color: UIColor(red: 0.96, green: 0.8, blue: 0.66, alpha: 1), roughness: 0.7, isMetallic: false)

        func part(_ size: SIMD3<Float>, at position: SIMD3<Float>, _ material: SimpleMaterial) {
            let radius = Swift.min(size.x, Swift.min(size.y, size.z)) * 0.2
            let entity = ModelEntity(mesh: .generateBox(size: size, cornerRadius: radius), materials: [material])
            entity.position = position
            root.addChild(entity)
        }

        switch model {
        case "rifle":
            part(SIMD3(0.07, 0.09, 0.62), at: SIMD3(0, 0.02, -0.16), body)
            part(SIMD3(0.035, 0.035, 0.34), at: SIMD3(0, 0.035, -0.62), metal)
            part(SIMD3(0.05, 0.05, 0.16), at: SIMD3(0, 0.1, -0.14), accent)
            part(SIMD3(0.05, 0.13, 0.06), at: SIMD3(0, -0.07, 0), metal)
        case "shotgun":
            part(SIMD3(0.08, 0.09, 0.5), at: SIMD3(0, 0.02, -0.12), body)
            part(SIMD3(0.07, 0.05, 0.36), at: SIMD3(0, 0.05, -0.5), metal)
            part(SIMD3(0.075, 0.05, 0.14), at: SIMD3(0, -0.02, -0.4), accent)
            part(SIMD3(0.05, 0.13, 0.06), at: SIMD3(0, -0.07, 0), metal)
        case "pistol":
            part(SIMD3(0.05, 0.075, 0.22), at: SIMD3(0, 0.04, -0.06), metal)
            part(SIMD3(0.045, 0.12, 0.06), at: SIMD3(0, -0.04, 0), body)
            part(SIMD3(0.052, 0.02, 0.06), at: SIMD3(0, 0.085, -0.02), accent)
        // Swung, not fired (`WeaponSpec.isMelee`, 8.8). They point down -Z
        // like the guns, so the swing is the same tilt for all of them.
        case "fist":
            part(SIMD3(0.1, 0.09, 0.11), at: SIMD3(0, 0, -0.04), glove)
            part(SIMD3(0.04, 0.04, 0.05), at: SIMD3(0.055, 0.02, -0.04), glove)
        case "sword":
            part(SIMD3(0.035, 0.1, 0.035), at: SIMD3(0, -0.02, 0), wood)
            part(SIMD3(0.16, 0.03, 0.04), at: SIMD3(0, 0, -0.04), metal)
            part(SIMD3(0.06, 0.012, 0.7), at: SIMD3(0, 0, -0.4), blade)
        case "bat":
            part(SIMD3(0.04, 0.04, 0.3), at: SIMD3(0, 0, -0.1), wood)
            part(SIMD3(0.07, 0.07, 0.42), at: SIMD3(0, 0, -0.45), wood)
        case "axe":
            part(SIMD3(0.04, 0.04, 0.62), at: SIMD3(0, 0, -0.25), wood)
            part(SIMD3(0.025, 0.2, 0.12), at: SIMD3(0, 0.08, -0.52), blade)
        case "knife":
            part(SIMD3(0.035, 0.05, 0.1), at: SIMD3(0, 0, -0.02), body)
            part(SIMD3(0.012, 0.04, 0.2), at: SIMD3(0, 0.005, -0.17), blade)
        case "spear":
            part(SIMD3(0.035, 0.035, 1.1), at: SIMD3(0, 0, -0.4), wood)
            part(SIMD3(0.05, 0.05, 0.16), at: SIMD3(0, 0, -1.02), blade)
        default:
            part(SIMD3(0.08, 0.1, 0.32), at: SIMD3(0, 0.03, -0.1), body)
            part(SIMD3(0.045, 0.045, 0.2), at: SIMD3(0, 0.04, -0.34), accent)
            part(SIMD3(0.05, 0.13, 0.06), at: SIMD3(0, -0.07, 0), metal)
        }
        RigidParts.merge(root)
        return root
    }

    /// Where shots leave the weapon, in the model's own space.
    static func muzzle(_ model: String) -> SIMD3<Float> {
        switch model {
        case "rifle": return SIMD3(0, 0.035, -0.8)
        case "shotgun": return SIMD3(0, 0.05, -0.68)
        case "pistol": return SIMD3(0, 0.04, -0.18)
        case "fist": return SIMD3(0, 0, -0.1)
        case "sword": return SIMD3(0, 0, -0.75)
        case "bat": return SIMD3(0, 0, -0.66)
        case "axe": return SIMD3(0, 0.08, -0.55)
        case "knife": return SIMD3(0, 0, -0.27)
        case "spear": return SIMD3(0, 0, -1.1)
        default: return SIMD3(0, 0.04, -0.45)
        }
    }
}
