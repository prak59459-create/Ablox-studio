import Foundation
import RealityKit
import simd
import UIKit
import AbloxCore

/// The newer hats, faces and pets, built from boxes, cylinders, cones and
/// spheres like the rest of the avatar. Kept apart from `AvatarEntity` so
/// each builder is compiled on its own and the avatar file stays small.
///
/// Positions follow `AvatarEntity`: hats are placed in the rig (the head's
/// top is at y 1.755), faces on the head (its front at z -0.228), pets at
/// their own origin, facing -Z.
enum AvatarWardrobe {

    // MARK: Colours used as they are

    static let ink = UnlitMaterial(color: UIColor(red: 0.1, green: 0.11, blue: 0.14, alpha: 1))
    static let white = material(red: 0.97, green: 0.97, blue: 0.96)
    static let dark = material(red: 0.14, green: 0.15, blue: 0.18)
    static let gold = material(red: 0.98, green: 0.78, blue: 0.2, metallic: 0.6)
    static let pink = UnlitMaterial(color: UIColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1))
    static let orange = UnlitMaterial(color: UIColor(red: 1, green: 0.6, blue: 0.15, alpha: 1))
    static let tearBlue = UnlitMaterial(color: UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 1))
    static let yellow = UnlitMaterial(color: UIColor(red: 1, green: 0.86, blue: 0.2, alpha: 1))
    static let red = material(red: 0.86, green: 0.15, blue: 0.2)
    static let green = material(red: 0.35, green: 0.8, blue: 0.4)

    static func material(red: CGFloat, green: CGFloat, blue: CGFloat, metallic: Float = 0) -> RealityKit.Material {
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(red: red, green: green, blue: blue, alpha: 1))
        material.roughness = .init(floatLiteral: 0.55)
        material.metallic = .init(floatLiteral: metallic)
        return material
    }

    // MARK: Pieces

    /// Adds one part to `parent` and returns it, for a turn or a name.
    @discardableResult
    static func add(_ mesh: MeshResource, _ material: RealityKit.Material, at position: SIMD3<Float>, to parent: Entity,
                    turn: Float = 0, axis: SIMD3<Float> = SIMD3<Float>(0, 0, 1), scale: SIMD3<Float>? = nil) -> ModelEntity {
        let part = ModelEntity(mesh: mesh, materials: [material])
        part.position = position
        if turn != 0 { part.orientation = simd_quatf(angle: turn, axis: axis) }
        if let scale { part.scale = scale }
        parent.addChild(part)
        return part
    }

    static func box(_ w: Float, _ h: Float, _ d: Float, corner: Float = 0) -> MeshResource {
        .generateBox(size: SIMD3<Float>(w, h, d), cornerRadius: corner)
    }

    static func ball(_ radius: Float) -> MeshResource { .generateSphere(radius: radius) }
    static func tube(_ height: Float, _ radius: Float) -> MeshResource { .abloxCylinder(height: height, radius: radius) }
    static func cone(_ height: Float, _ radius: Float) -> MeshResource { .abloxCone(height: height, radius: radius) }

    // MARK: Hats

    /// A hat in `main` (the hat colour or the legs' colour), or nil for the
    /// hats `AvatarEntity` draws itself.
    static func hat(_ hat: AvatarProfile.HatStyle, main: RealityKit.Material) -> Entity? {
        let root = Entity()
        root.name = "ablox.avatar.hat"
        switch hat {
        case .none, .cap, .crown, .antenna, .halo:
            return nil
        case .topHat:
            add(tube(0.03, 0.34), main, at: [0, 1.77, 0], to: root)
            add(tube(0.34, 0.21), main, at: [0, 1.95, 0], to: root)
            add(tube(0.06, 0.215), dark, at: [0, 1.82, 0], to: root)
        case .beanie:
            add(ball(0.26), main, at: [0, 1.74, 0], to: root, scale: [1, 0.72, 1])
            add(tube(0.07, 0.255), white, at: [0, 1.72, 0], to: root)
            add(ball(0.07), white, at: [0, 1.95, 0], to: root)
        case .cowboy:
            add(tube(0.03, 0.44), main, at: [0, 1.77, 0], to: root, scale: [1, 1, 0.8])
            add(tube(0.22, 0.2), main, at: [0, 1.9, 0], to: root)
            add(tube(0.04, 0.205), dark, at: [0, 1.81, 0], to: root)
        case .wizard:
            add(tube(0.03, 0.36), main, at: [0, 1.77, 0], to: root)
            add(cone(0.55, 0.25), main, at: [0, 2.06, 0], to: root, turn: 0.15)
            add(ball(0.04), yellow, at: [0.1, 2.0, -0.2], to: root)
            add(ball(0.03), yellow, at: [-0.08, 1.92, -0.22], to: root)
        case .pirate:
            add(box(0.62, 0.2, 0.3, corner: 0.05), dark, at: [0, 1.86, 0], to: root)
            add(box(0.12, 0.1, 0.02), white, at: [0, 1.88, -0.16], to: root)
            add(box(0.64, 0.04, 0.32), main, at: [0, 1.77, 0], to: root)
        case .chef:
            add(tube(0.28, 0.2), white, at: [0, 1.9, 0], to: root)
            add(ball(0.25), white, at: [0, 2.1, 0], to: root, scale: [1, 0.7, 1])
        case .party:
            add(cone(0.42, 0.15), main, at: [0, 1.97, 0], to: root)
            add(ball(0.055), yellow, at: [0, 2.2, 0], to: root)
            add(tube(0.03, 0.12), white, at: [0, 1.88, 0], to: root)
        case .headphones:
            add(box(0.54, 0.05, 0.08, corner: 0.02), dark, at: [0, 1.8, 0], to: root)
            for side: Float in [-1, 1] {
                add(box(0.05, 0.22, 0.08), dark, at: [side * 0.27, 1.68, 0], to: root)
                add(tube(0.08, 0.1), main, at: [side * 0.27, 1.53, 0], to: root, turn: .pi / 2)
            }
        case .bunnyEars:
            for side: Float in [-1, 1] {
                add(box(0.09, 0.32, 0.05, corner: 0.03), white, at: [side * 0.1, 1.94, 0], to: root, turn: -side * 0.15)
                add(box(0.05, 0.24, 0.01), pink, at: [side * 0.1, 1.94, -0.03], to: root, turn: -side * 0.15)
            }
        case .horns:
            for side: Float in [-1, 1] {
                add(cone(0.18, 0.055), white, at: [side * 0.16, 1.83, -0.04], to: root, turn: -side * 0.45)
            }
        case .flowerCrown:
            add(tube(0.04, 0.24), green, at: [0, 1.76, 0], to: root)
            let colours: [RealityKit.Material] = [pink, yellow, white, main]
            for index in 0..<8 {
                let angle = Float(index) / 8 * 2 * .pi
                add(ball(0.055), colours[index % colours.count], at: [cos(angle) * 0.24, 1.79, sin(angle) * 0.24], to: root)
            }
        case .bow:
            add(box(0.16, 0.12, 0.05, corner: 0.03), main, at: [-0.1, 1.82, -0.05], to: root, turn: 0.35)
            add(box(0.16, 0.12, 0.05, corner: 0.03), main, at: [0.1, 1.82, -0.05], to: root, turn: -0.35)
            add(box(0.06, 0.06, 0.06, corner: 0.02), main, at: [0, 1.82, -0.05], to: root)
        case .helmet:
            add(ball(0.3), main, at: [0, 1.66, 0], to: root, scale: [1, 0.78, 1])
            add(box(0.4, 0.12, 0.04), dark, at: [0, 1.6, -0.27], to: root)
        case .viking:
            add(ball(0.27), dark, at: [0, 1.74, 0], to: root, scale: [1, 0.62, 1])
            add(tube(0.05, 0.27), gold, at: [0, 1.72, 0], to: root)
            for side: Float in [-1, 1] {
                add(cone(0.24, 0.06), white, at: [side * 0.3, 1.86, 0], to: root, turn: -side * 0.9)
            }
        case .beret:
            add(tube(0.08, 0.27), main, at: [0.03, 1.8, 0], to: root, turn: -0.12)
            add(tube(0.05, 0.015), main, at: [0.03, 1.86, 0], to: root)
        case .propeller:
            add(ball(0.25), main, at: [0, 1.74, 0], to: root, scale: [1, 0.55, 1])
            add(tube(0.08, 0.02), dark, at: [0, 1.88, 0], to: root)
            let blades = add(box(0.5, 0.012, 0.07, corner: 0.005), red, at: [0, 1.93, 0], to: root)
            blades.name = AvatarWardrobe.spinningPart
        case .graduate:
            add(tube(0.12, 0.22), dark, at: [0, 1.8, 0], to: root)
            add(box(0.56, 0.03, 0.56), dark, at: [0, 1.88, 0], to: root, turn: .pi / 4, axis: [0, 1, 0])
            add(box(0.02, 0.18, 0.02), gold, at: [0.26, 1.8, -0.1], to: root)
        case .santa:
            add(cone(0.42, 0.24), red, at: [0, 1.98, 0.05], to: root, turn: 0.35, axis: [1, 0, 0])
            add(tube(0.07, 0.25), white, at: [0, 1.78, 0], to: root)
            add(ball(0.06), white, at: [0, 2.14, 0.17], to: root)
        case .witch:
            add(tube(0.03, 0.42), main, at: [0, 1.77, 0], to: root)
            add(cone(0.6, 0.22), main, at: [0, 2.08, 0.02], to: root, turn: -0.12, axis: [1, 0, 0])
            add(tube(0.05, 0.225), gold, at: [0, 1.82, 0], to: root)
        case .headband:
            add(tube(0.08, 0.235), main, at: [0, 1.66, 0], to: root)
            for side: Float in [-1, 1] {
                add(box(0.05, 0.16, 0.02), main, at: [side * 0.06, 1.6, 0.25], to: root, turn: side * 0.4)
            }
        }
        return root
    }

    /// The part of a hat that turns by itself (a propeller).
    static let spinningPart = "ablox.avatar.hat.spin"

    // MARK: Faces

    /// A face on the front of the head, or nil for the faces `AvatarEntity`
    /// draws itself.
    static func face(_ face: AvatarProfile.Face) -> Entity? {
        let group = Entity()
        let front: Float = -0.228
        func part(_ w: Float, _ h: Float, _ x: Float, _ y: Float, _ m: RealityKit.Material = ink, turn: Float = 0) {
            add(box(w, h, 0.012), m, at: [x, y, front], to: group, turn: turn)
        }
        func eyes(_ w: Float = 0.07, _ h: Float = 0.09) {
            part(w, h, -0.1, 0.05)
            part(w, h, 0.1, 0.05)
        }
        /// "^ ^": a closed, smiling eye.
        func closedEye(_ x: Float) {
            part(0.06, 0.022, x - 0.022, 0.05, turn: 0.5)
            part(0.06, 0.022, x + 0.022, 0.05, turn: -0.5)
        }
        switch face {
        case .smile, .grin, .wink, .cool, .surprised, .sleepy, .cat, .robot, .heart:
            return nil
        case .angry:
            eyes(0.07, 0.07)
            part(0.1, 0.025, -0.1, 0.12, turn: -0.35)
            part(0.1, 0.025, 0.1, 0.12, turn: 0.35)
            part(0.14, 0.03, 0, -0.1)
        case .sad:
            eyes(0.06, 0.08)
            part(0.09, 0.02, -0.1, 0.12, turn: 0.3)
            part(0.09, 0.02, 0.1, 0.12, turn: -0.3)
            part(0.1, 0.025, 0, -0.1)
            part(0.025, 0.05, -0.12, -0.02, tearBlue)
        case .tongue:
            eyes()
            part(0.16, 0.03, 0, -0.08)
            part(0.07, 0.07, 0.03, -0.12, pink)
        case .starEyes:
            for x: Float in [-0.1, 0.1] {
                part(0.1, 0.035, x, 0.05, yellow)
                part(0.035, 0.1, x, 0.05, yellow)
                part(0.07, 0.035, x, 0.05, yellow, turn: .pi / 4)
                part(0.07, 0.035, x, 0.05, yellow, turn: -.pi / 4)
            }
            part(0.16, 0.035, 0, -0.09)
        case .dizzy:
            for x: Float in [-0.1, 0.1] {
                part(0.1, 0.022, x, 0.05, turn: .pi / 4)
                part(0.1, 0.022, x, 0.05, turn: -.pi / 4)
            }
            for i in 0..<4 { part(0.045, 0.02, -0.07 + Float(i) * 0.045, -0.09 + (i % 2 == 0 ? 0.01 : -0.01)) }
        case .glasses:
            eyes(0.05, 0.06)
            for x: Float in [-0.1, 0.1] {
                part(0.13, 0.02, x, 0.1)
                part(0.13, 0.02, x, 0.0)
                part(0.02, 0.1, x - 0.065, 0.05)
                part(0.02, 0.1, x + 0.065, 0.05)
            }
            part(0.06, 0.02, 0, 0.07)
            part(0.14, 0.03, 0, -0.1)
        case .monocle:
            eyes()
            part(0.14, 0.018, 0.1, 0.11, gold)
            part(0.14, 0.018, 0.1, -0.01, gold)
            part(0.018, 0.12, 0.03, 0.05, gold)
            part(0.018, 0.12, 0.17, 0.05, gold)
            part(0.012, 0.16, 0.17, -0.09, gold)
            part(0.14, 0.03, -0.02, -0.1)
        case .blush:
            eyes()
            part(0.16, 0.035, 0, -0.09)
            part(0.07, 0.035, -0.16, -0.03, pink)
            part(0.07, 0.035, 0.16, -0.03, pink)
        case .alien:
            part(0.12, 0.15, -0.1, 0.04, turn: 0.35)
            part(0.12, 0.15, 0.1, 0.04, turn: -0.35)
            part(0.06, 0.02, 0, -0.11)
        case .eyepatch:
            part(0.1, 0.1, -0.1, 0.05)
            part(0.5, 0.02, 0, 0.09, turn: -0.25)
            part(0.07, 0.09, 0.1, 0.05)
            part(0.16, 0.035, 0.02, -0.09)
        case .ninja:
            part(0.46, 0.2, 0, -0.08)
            eyes(0.08, 0.05)
            part(0.46, 0.05, 0, 0.13)
        case .joy:
            closedEye(-0.1)
            closedEye(0.1)
            part(0.18, 0.07, 0, -0.1, white)
            part(0.03, 0.07, -0.17, 0.0, tearBlue)
            part(0.03, 0.07, 0.17, 0.0, tearBlue)
        case .mustache:
            eyes()
            part(0.11, 0.035, -0.055, -0.07, turn: 0.25)
            part(0.11, 0.035, 0.055, -0.07, turn: -0.25)
            part(0.07, 0.02, 0, -0.12)
        case .fangs:
            part(0.07, 0.09, -0.1, 0.05, red)
            part(0.07, 0.09, 0.1, 0.05, red)
            part(0.18, 0.03, 0, -0.08)
            part(0.025, 0.045, -0.05, -0.11, white)
            part(0.025, 0.045, 0.05, -0.11, white)
        case .happy:
            closedEye(-0.1)
            closedEye(0.1)
            part(0.18, 0.035, 0, -0.09)
            part(0.04, 0.03, -0.09, -0.07, turn: 0.4)
            part(0.04, 0.03, 0.09, -0.07, turn: -0.4)
        }
        return group
    }

    // MARK: Pets

    /// A pet in `skin` (the pet colour), or nil for the pets `AvatarEntity`
    /// builds itself.
    static func pet(_ pet: AvatarProfile.Pet, skin: RealityKit.Material) -> Entity? {
        let root = Entity()
        func part(_ size: SIMD3<Float>, _ at: SIMD3<Float>, _ m: RealityKit.Material? = nil, tilt: Float = 0) {
            add(.generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.2), m ?? skin, at: at, to: root, turn: tilt)
        }
        func eyes(y: Float, z: Float, spread: Float = 0.04, size: Float = 0.03) {
            part([size, size, 0.01], [-spread, y, z], ink)
            part([size, size, 0.01], [spread, y, z], ink)
        }
        switch pet {
        case .none, .cat, .dog, .bunny, .bird, .slime, .robot, .dragon:
            return nil
        case .fox:
            part([0.2, 0.18, 0.34], [0, 0.19, 0])
            part([0.2, 0.18, 0.2], [0, 0.34, -0.2])
            part([0.08, 0.06, 0.1], [0, 0.31, -0.33], white)
            for x: Float in [-0.07, 0.07] {
                part([0.06, 0.11, 0.06], [x, 0.05, -0.12])
                part([0.06, 0.11, 0.06], [x, 0.05, 0.12])
                part([0.06, 0.1, 0.04], [x, 0.47, -0.2], tilt: x < 0 ? 0.25 : -0.25)
            }
            part([0.1, 0.1, 0.26], [0, 0.26, 0.28], tilt: 0)
            part([0.1, 0.1, 0.08], [0, 0.26, 0.43], white)
            eyes(y: 0.37, z: -0.305, spread: 0.055)
        case .panda:
            part([0.26, 0.24, 0.34], [0, 0.2, 0], white)
            part([0.24, 0.22, 0.22], [0, 0.4, -0.2], white)
            for x: Float in [-0.08, 0.08] {
                part([0.08, 0.13, 0.08], [x, 0.06, -0.12], dark)
                part([0.08, 0.13, 0.08], [x, 0.06, 0.12], dark)
                part([0.07, 0.07, 0.05], [x * 1.1, 0.53, -0.2], dark)
                part([0.06, 0.07, 0.01], [x * 0.7, 0.42, -0.311], dark)
            }
            part([0.04, 0.03, 0.01], [0, 0.36, -0.312], ink)
        case .penguin:
            part([0.22, 0.34, 0.2], [0, 0.2, 0], dark)
            part([0.16, 0.26, 0.02], [0, 0.18, -0.1], white)
            part([0.06, 0.04, 0.08], [0, 0.3, -0.13], orange)
            part([0.06, 0.03, 0.08], [-0.05, 0.02, -0.04], orange)
            part([0.06, 0.03, 0.08], [0.05, 0.02, -0.04], orange)
            part([0.03, 0.18, 0.1], [-0.12, 0.2, 0], dark, tilt: 0.2)
            part([0.03, 0.18, 0.1], [0.12, 0.2, 0], dark, tilt: -0.2)
            eyes(y: 0.34, z: -0.105, spread: 0.045, size: 0.025)
        case .frog:
            part([0.3, 0.14, 0.26], [0, 0.09, 0])
            for x: Float in [-0.08, 0.08] {
                add(ball(0.05), white, at: [x, 0.19, -0.08], to: root)
                part([0.03, 0.03, 0.01], [x, 0.2, -0.13], ink)
                part([0.08, 0.04, 0.1], [x * 1.9, 0.02, 0.06])
            }
            part([0.16, 0.012, 0.01], [0, 0.07, -0.131], ink)
        case .turtle:
            add(ball(0.18), green, at: [0, 0.12, 0], to: root, scale: [1, 0.55, 1.2])
            part([0.1, 0.09, 0.12], [0, 0.1, -0.24])
            for x: Float in [-0.12, 0.12] {
                part([0.06, 0.06, 0.06], [x, 0.03, -0.12])
                part([0.06, 0.06, 0.06], [x, 0.03, 0.12])
            }
            eyes(y: 0.12, z: -0.301, spread: 0.03, size: 0.02)
        case .duck:
            part([0.2, 0.16, 0.26], [0, 0.12, 0])
            part([0.14, 0.14, 0.14], [0, 0.26, -0.1])
            part([0.08, 0.03, 0.08], [0, 0.24, -0.2], orange)
            part([0.03, 0.08, 0.14], [-0.11, 0.14, 0.02])
            part([0.03, 0.08, 0.14], [0.11, 0.14, 0.02])
            eyes(y: 0.3, z: -0.171, spread: 0.04, size: 0.022)
        case .bee:
            part([0.16, 0.14, 0.22], [0, 0, 0], yellow)
            part([0.165, 0.145, 0.04], [0, 0, 0.0], ink)
            part([0.165, 0.145, 0.04], [0, 0, 0.07], ink)
            part([0.16, 0.012, 0.1], [-0.13, 0.08, 0.02], white, tilt: 0.4)
            part([0.16, 0.012, 0.1], [0.13, 0.08, 0.02], white, tilt: -0.4)
            eyes(y: 0.02, z: -0.111, spread: 0.035, size: 0.025)
        case .ghost:
            add(ball(0.16), white, at: [0, 0, 0], to: root, scale: [1, 1.25, 1])
            part([0.3, 0.05, 0.3], [0, -0.17, 0], white)
            part([0.035, 0.06, 0.01], [-0.05, 0.04, -0.16], ink)
            part([0.035, 0.06, 0.01], [0.05, 0.04, -0.16], ink)
            part([0.04, 0.04, 0.01], [0, -0.03, -0.16], ink)
        case .unicorn:
            part([0.22, 0.2, 0.36], [0, 0.22, 0], white)
            part([0.18, 0.2, 0.2], [0, 0.4, -0.2], white)
            add(cone(0.16, 0.03), gold, at: [0, 0.57, -0.24], to: root, turn: -0.3, axis: [1, 0, 0])
            part([0.06, 0.24, 0.24], [0, 0.4, -0.05], pink)
            part([0.06, 0.2, 0.06], [0, 0.26, 0.21], pink, tilt: 0)
            for x: Float in [-0.07, 0.07] {
                part([0.06, 0.13, 0.06], [x, 0.06, -0.12], white)
                part([0.06, 0.13, 0.06], [x, 0.06, 0.12], white)
            }
            eyes(y: 0.43, z: -0.301, spread: 0.05)
        case .owl:
            part([0.2, 0.24, 0.18], [0, 0, 0])
            for x: Float in [-0.05, 0.05] {
                add(ball(0.045), white, at: [x, 0.05, -0.08], to: root)
                part([0.025, 0.025, 0.01], [x, 0.05, -0.125], ink)
                part([0.05, 0.06, 0.03], [x * 1.4, 0.14, 0], tilt: x < 0 ? 0.3 : -0.3)
            }
            part([0.035, 0.04, 0.04], [0, 0.0, -0.1], orange)
            part([0.03, 0.16, 0.12], [-0.11, -0.02, 0.02], tilt: 0.15)
            part([0.03, 0.16, 0.12], [0.11, -0.02, 0.02], tilt: -0.15)
        }
        root.name = "ablox.avatar.pet"
        return root
    }
}
