import Foundation
import RealityKit
import simd
import UIKit

/// A blocky avatar built from RealityKit primitives.
///
/// No asset files: a Swift Playground should be a handful of `.swift` files
/// you can read, and a rigged character model would be the only binary in the
/// project. Primitives also mean an avatar can be recoloured instantly from
/// `AvatarProfile` without touching a texture.
public final class AvatarEntity: Entity {

    public private(set) var peerID: PeerID
    public private(set) var profile: AvatarProfile

    /// Everything that is the person, so sitting down in a car moves it all
    /// at once. The ride itself hangs off the avatar, not the rig.
    private let rig = Entity()
    private let body = ModelEntity()
    private let head = ModelEntity()
    private let leftArm = ModelEntity()
    private let rightArm = ModelEntity()
    private let leftLeg = ModelEntity()
    private let rightLeg = ModelEntity()
    private var hatEntity: ModelEntity?
    private var faceEntity: Entity?
    private var appliedFace: AvatarProfile.Face?
    private var appliedFaceHeadColor: ColorRGBA?
    private var petEntity: Entity?
    private var appliedPet: AvatarProfile.Pet = .none
    private var appliedPetColor: ColorRGBA?
    private var petPhase: Float = 0
    private var rideEntity: Entity?
    private var appliedRide: AvatarProfile.Ride = .none
    private var appliedRideColor: ColorRGBA?
    private var heldWeapon: Entity?
    public private(set) var heldWeaponModel: String?

    /// Where the network says this avatar is. The entity eases toward it
    /// rather than snapping, which hides the 15 Hz transform rate.
    public var targetPosition: Vec3
    public var targetYawDegrees: Float

    /// Accumulated distance walked, used to phase the limb swing so the walk
    /// cycle is tied to movement rather than to wall-clock time.
    private var strideDistance: Float = 0

    /// How far a ride lowers or raises the person in it.
    private var seatHeight: Float = 0

    /// A wave, a dance… playing now, and for how long so far.
    private var gesture: Emote?
    private var gestureTime: Float = 0

    public init(peerID: PeerID, profile: AvatarProfile, position: Vec3) {
        self.peerID = peerID
        self.profile = profile
        self.targetPosition = position
        self.targetYawDegrees = 0
        super.init()

        name = "ablox.avatar.\(peerID)"
        self.position = position.simd

        buildRig()
        apply(profile: profile)
    }

    // No explicit global-actor annotation: a subclass inherits its
    // superclass's isolation, and RealityKit's `Entity` is @MainActor on newer
    // SDKs and not on older ones. Spelling it out here would be an error
    // against whichever of the two this is built with.
    required init() {
        self.peerID = PeerID()
        self.profile = .default
        self.targetPosition = .zero
        self.targetYawDegrees = 0
        super.init()
        buildRig()
        apply(profile: .default)
    }

    // MARK: Rig

    private func buildRig() {
        // Proportions are deliberately chunky — readable from the third-person
        // camera distance, and forgiving of the box collider that represents
        // the player in `WorldCollider`.
        body.model = ModelComponent(mesh: .generateBox(size: SIMD3<Float>(0.6, 0.7, 0.35), cornerRadius: 0.05), materials: [])
        body.position = SIMD3<Float>(0, 0.95, 0)

        head.model = ModelComponent(mesh: .generateBox(size: SIMD3<Float>(0.45, 0.45, 0.45), cornerRadius: 0.06), materials: [])
        head.position = SIMD3<Float>(0, 1.53, 0)

        for (arm, side) in [(leftArm, Float(-1)), (rightArm, Float(1))] {
            arm.model = ModelComponent(mesh: .generateBox(size: SIMD3<Float>(0.18, 0.6, 0.18), cornerRadius: 0.04), materials: [])
            arm.position = SIMD3<Float>(side * 0.39, 0.95, 0)
        }

        for (leg, side) in [(leftLeg, Float(-1)), (rightLeg, Float(1))] {
            leg.model = ModelComponent(mesh: .generateBox(size: SIMD3<Float>(0.22, 0.6, 0.22), cornerRadius: 0.04), materials: [])
            leg.position = SIMD3<Float>(side * 0.16, 0.3, 0)
        }

        for part in [body, head, leftArm, rightArm, leftLeg, rightLeg] {
            rig.addChild(part)
        }
        addChild(rig)
    }

    // MARK: Appearance

    public func apply(profile: AvatarProfile) {
        self.profile = profile

        let bodyMaterial = material(profile.bodyColor)
        let headMaterial = material(profile.headColor)
        let accentMaterial = material(profile.accentColor)

        body.model?.materials = [bodyMaterial]
        head.model?.materials = [headMaterial]
        leftArm.model?.materials = [headMaterial]
        rightArm.model?.materials = [headMaterial]
        leftLeg.model?.materials = [accentMaterial]
        rightLeg.model?.materials = [accentMaterial]

        // `height` scales the whole rig, so a taller avatar's limbs and hat
        // stay in proportion without recomputing every offset.
        scale = SIMD3<Float>(repeating: profile.height)

        applyHat(profile.hat, material: profile.hatColor.map { material($0) } ?? accentMaterial)
        applyRide(profile.ride, color: profile.rideColor)
        applyFace(profile.face)
        applyPet(profile.pet, color: profile.petColor)
    }

    // MARK: Face

    /// Eyes and a mouth on the front of the head (the avatar faces -Z).
    private func applyFace(_ face: AvatarProfile.Face) {
        // The cat's ears are the head's colour, so a new head colour
        // rebuilds them too.
        guard face != appliedFace || (face == .cat && profile.headColor != appliedFaceHeadColor) else { return }
        appliedFace = face
        appliedFaceHeadColor = profile.headColor
        faceEntity?.removeFromParent()
        let group = Entity()
        let ink = UnlitMaterial(color: UIColor(red: 0.1, green: 0.11, blue: 0.14, alpha: 1))
        let front: Float = -0.228
        func part(_ w: Float, _ h: Float, _ x: Float, _ y: Float, _ material: RealityKit.Material? = nil) {
            let box = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(w, h, 0.012)), materials: [material ?? ink])
            box.position = SIMD3<Float>(x, y, front)
            group.addChild(box)
        }
        func eyes(_ w: Float = 0.07, _ h: Float = 0.09) {
            part(w, h, -0.1, 0.05)
            part(w, h, 0.1, 0.05)
        }
        switch face {
        case .smile:
            eyes()
            part(0.16, 0.035, 0, -0.09)
        case .grin:
            eyes()
            part(0.24, 0.07, 0, -0.09, UnlitMaterial(color: .white))
            part(0.26, 0.02, 0, -0.05)
        case .wink:
            part(0.09, 0.022, -0.1, 0.05)
            part(0.07, 0.09, 0.1, 0.05)
            part(0.16, 0.035, 0.02, -0.09)
        case .cool:
            part(0.38, 0.1, 0, 0.05)
            part(0.14, 0.03, 0, -0.1)
        case .surprised:
            eyes(0.08, 0.1)
            part(0.08, 0.08, 0, -0.1)
        case .sleepy:
            part(0.09, 0.022, -0.1, 0.04)
            part(0.09, 0.022, 0.1, 0.04)
            part(0.07, 0.03, 0, -0.1)
        case .cat:
            eyes(0.06, 0.1)
            part(0.05, 0.03, -0.035, -0.08)
            part(0.05, 0.03, 0.035, -0.08)
            part(0.04, 0.03, 0, -0.05, UnlitMaterial(color: UIColor(red: 0.96, green: 0.45, blue: 0.6, alpha: 1)))
            // Ears, on top of the head.
            for side: Float in [-1, 1] {
                let earMaterials: [RealityKit.Material] = head.model?.materials ?? [ink]
                let ear = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.1, 0.12, 0.06)), materials: earMaterials)
                ear.position = SIMD3<Float>(side * 0.14, 0.27, 0)
                ear.orientation = simd_quatf(angle: side * 0.3, axis: SIMD3<Float>(0, 0, 1))
                group.addChild(ear)
            }
        case .robot:
            part(0.34, 0.09, 0, 0.05, UnlitMaterial(color: UIColor(red: 0.3, green: 0.85, blue: 1, alpha: 1)))
            for i in 0..<4 { part(0.03, 0.05, -0.06 + Float(i) * 0.04, -0.1) }
        case .heart:
            let pink = UnlitMaterial(color: UIColor(red: 0.98, green: 0.3, blue: 0.5, alpha: 1))
            for x: Float in [-0.1, 0.1] {
                part(0.05, 0.05, x - 0.022, 0.07, pink)
                part(0.05, 0.05, x + 0.022, 0.07, pink)
                part(0.06, 0.05, x, 0.035, pink)
            }
            part(0.16, 0.035, 0, -0.09)
        }
        head.addChild(group)
        faceEntity = group
    }

    // MARK: Pet

    /// A small friend beside them: at the feet, or by the shoulder if it
    /// flies. Built from boxes like everything else.
    private func applyPet(_ pet: AvatarProfile.Pet, color: ColorRGBA) {
        guard pet != appliedPet || color != appliedPetColor else { return }
        appliedPet = pet
        appliedPetColor = color
        petEntity?.removeFromParent()
        petEntity = nil
        guard pet != .none else { return }
        let root = Entity()
        let skin = material(color)
        let dark = UnlitMaterial(color: UIColor(red: 0.1, green: 0.11, blue: 0.14, alpha: 1))
        func box(_ size: SIMD3<Float>, _ at: SIMD3<Float>, _ m: RealityKit.Material? = nil, tilt: Float = 0) {
            let part = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.2), materials: [m ?? skin])
            part.position = at
            if tilt != 0 { part.orientation = simd_quatf(angle: tilt, axis: SIMD3<Float>(0, 0, 1)) }
            root.addChild(part)
        }
        switch pet {
        case .none:
            return
        case .cat, .dog:
            box(SIMD3<Float>(0.22, 0.2, 0.36), SIMD3<Float>(0, 0.2, 0))
            box(SIMD3<Float>(0.22, 0.2, 0.2), SIMD3<Float>(0, 0.36, -0.2))
            for x: Float in [-0.07, 0.07] {
                box(SIMD3<Float>(0.06, 0.12, 0.06), SIMD3<Float>(x, 0.05, -0.12))
                box(SIMD3<Float>(0.06, 0.12, 0.06), SIMD3<Float>(x, 0.05, 0.12))
                box(SIMD3<Float>(0.035, 0.035, 0.01), SIMD3<Float>(x * 0.8, 0.39, -0.305), dark)
            }
            if pet == .cat {
                box(SIMD3<Float>(0.06, 0.08, 0.04), SIMD3<Float>(-0.07, 0.5, -0.2), tilt: 0.3)
                box(SIMD3<Float>(0.06, 0.08, 0.04), SIMD3<Float>(0.07, 0.5, -0.2), tilt: -0.3)
                box(SIMD3<Float>(0.04, 0.24, 0.04), SIMD3<Float>(0, 0.35, 0.2), tilt: 0.2)
            } else {
                box(SIMD3<Float>(0.06, 0.12, 0.05), SIMD3<Float>(-0.12, 0.4, -0.2), tilt: -0.4)
                box(SIMD3<Float>(0.06, 0.12, 0.05), SIMD3<Float>(0.12, 0.4, -0.2), tilt: 0.4)
                box(SIMD3<Float>(0.08, 0.06, 0.08), SIMD3<Float>(0, 0.33, -0.32))
                box(SIMD3<Float>(0.04, 0.16, 0.04), SIMD3<Float>(0, 0.32, 0.2), tilt: -0.5)
            }
        case .bunny:
            box(SIMD3<Float>(0.22, 0.22, 0.26), SIMD3<Float>(0, 0.14, 0))
            box(SIMD3<Float>(0.18, 0.18, 0.18), SIMD3<Float>(0, 0.3, -0.12))
            box(SIMD3<Float>(0.05, 0.22, 0.04), SIMD3<Float>(-0.05, 0.5, -0.12))
            box(SIMD3<Float>(0.05, 0.22, 0.04), SIMD3<Float>(0.05, 0.5, -0.12))
            box(SIMD3<Float>(0.03, 0.03, 0.01), SIMD3<Float>(-0.04, 0.33, -0.215), dark)
            box(SIMD3<Float>(0.03, 0.03, 0.01), SIMD3<Float>(0.04, 0.33, -0.215), dark)
        case .bird:
            box(SIMD3<Float>(0.14, 0.14, 0.2), SIMD3<Float>(0, 0, 0))
            box(SIMD3<Float>(0.04, 0.03, 0.06), SIMD3<Float>(0, 0.02, -0.13), UnlitMaterial(color: .orange))
            box(SIMD3<Float>(0.18, 0.02, 0.1), SIMD3<Float>(-0.12, 0.03, 0.02), tilt: 0.4)
            box(SIMD3<Float>(0.18, 0.02, 0.1), SIMD3<Float>(0.12, 0.03, 0.02), tilt: -0.4)
        case .slime:
            let blob = ModelEntity(mesh: .generateSphere(radius: 0.17), materials: [skin])
            blob.position = SIMD3<Float>(0, 0.14, 0)
            blob.scale = SIMD3<Float>(1.1, 0.8, 1.1)
            root.addChild(blob)
            box(SIMD3<Float>(0.03, 0.05, 0.01), SIMD3<Float>(-0.05, 0.18, -0.17), dark)
            box(SIMD3<Float>(0.03, 0.05, 0.01), SIMD3<Float>(0.05, 0.18, -0.17), dark)
        case .robot:
            box(SIMD3<Float>(0.24, 0.22, 0.2), SIMD3<Float>(0, 0.22, 0))
            box(SIMD3<Float>(0.18, 0.14, 0.16), SIMD3<Float>(0, 0.41, 0))
            box(SIMD3<Float>(0.12, 0.03, 0.01), SIMD3<Float>(0, 0.42, -0.085), UnlitMaterial(color: UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 1)))
            box(SIMD3<Float>(0.02, 0.12, 0.02), SIMD3<Float>(0, 0.54, 0))
            box(SIMD3<Float>(0.1, 0.1, 0.1), SIMD3<Float>(0, 0.06, 0), dark)
        case .dragon:
            box(SIMD3<Float>(0.18, 0.16, 0.3), SIMD3<Float>(0, 0, 0))
            box(SIMD3<Float>(0.14, 0.13, 0.16), SIMD3<Float>(0, 0.1, -0.2))
            box(SIMD3<Float>(0.26, 0.02, 0.16), SIMD3<Float>(-0.2, 0.08, 0.02), tilt: 0.5)
            box(SIMD3<Float>(0.26, 0.02, 0.16), SIMD3<Float>(0.2, 0.08, 0.02), tilt: -0.5)
            box(SIMD3<Float>(0.05, 0.05, 0.22), SIMD3<Float>(0, -0.02, 0.24))
            box(SIMD3<Float>(0.03, 0.03, 0.01), SIMD3<Float>(-0.04, 0.13, -0.285), UnlitMaterial(color: .yellow))
            box(SIMD3<Float>(0.03, 0.03, 0.01), SIMD3<Float>(0.04, 0.13, -0.285), UnlitMaterial(color: .yellow))
        }
        root.name = "ablox.avatar.pet"
        root.position = petHome
        addChild(root)
        petEntity = root
    }

    /// Where the pet stays, beside and a little behind.
    private var petHome: SIMD3<Float> {
        appliedPet.flies ? SIMD3<Float>(0.55, 1.75, 0.25) : SIMD3<Float>(0.7, 0, 0.35)
    }

    private func material(_ color: ColorRGBA) -> RealityKit.Material {
        var material = SimpleMaterial()
        material.color = .init(tint: UIColor(
            red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1
        ))
        material.roughness = .init(floatLiteral: 0.55)
        material.metallic = .init(floatLiteral: 0.0)
        return material
    }

    private func applyHat(_ hat: AvatarProfile.HatStyle, material: RealityKit.Material) {
        hatEntity?.removeFromParent()
        hatEntity = nil
        guard hat != .none else { return }

        let mesh: MeshResource
        let offset: SIMD3<Float>
        switch hat {
        case .none:
            return
        case .cap:
            mesh = .generateBox(size: SIMD3<Float>(0.5, 0.12, 0.5), cornerRadius: 0.04)
            offset = SIMD3<Float>(0, 1.8, 0)
        case .crown:
            mesh = .abloxCylinder(height: 0.2, radius: 0.26)
            offset = SIMD3<Float>(0, 1.86, 0)
        case .antenna:
            mesh = .abloxCylinder(height: 0.5, radius: 0.03)
            offset = SIMD3<Float>(0, 2.0, 0)
        case .halo:
            mesh = .abloxCylinder(height: 0.04, radius: 0.32)
            offset = SIMD3<Float>(0, 2.05, 0)
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = offset
        entity.name = "ablox.avatar.hat"
        rig.addChild(entity)
        hatEntity = entity
    }

    // MARK: Ride

    /// Builds what they ride from boxes and cylinders, front toward -Z like
    /// the avatar. Seated rides lower the person into the seat and hide the
    /// legs; the rest leave them standing on it or wearing it.
    private func applyRide(_ ride: AvatarProfile.Ride, color: ColorRGBA) {
        guard ride != appliedRide || color != appliedRideColor else { return }
        appliedRide = ride
        appliedRideColor = color
        rideEntity?.removeFromParent()
        rideEntity = nil

        let seat: Float
        switch ride {
        case .none: seat = 0
        case .car: seat = -0.45
        case .sports: seat = -0.55
        case .truck: seat = -0.1
        case .kart: seat = -0.55
        case .bike: seat = 0.15
        case .scooter: seat = 0.1
        case .jetpack: seat = 0
        case .hoverboard: seat = 0.18
        }
        seatHeight = seat
        rig.position = SIMD3<Float>(0, seat, 0)
        leftLeg.isEnabled = !ride.isSeated
        rightLeg.isEnabled = !ride.isSeated
        guard ride != .none else { return }

        let paint = material(color)
        let dark = material(ColorRGBA(r: 0.12, g: 0.13, b: 0.16))
        let glass = material(ColorRGBA(r: 0.73, g: 0.9, b: 0.99))
        let lamp = UnlitMaterial(color: UIColor(red: 1, green: 0.97, blue: 0.78, alpha: 1))
        let brake = UnlitMaterial(color: UIColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1))
        let flame = UnlitMaterial(color: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
        let glow = UnlitMaterial(color: UIColor(red: 0.2, green: 0.9, blue: 1, alpha: 1))

        let root = Entity()
        root.name = "ablox.avatar.ride"
        func box(_ size: SIMD3<Float>, at position: SIMD3<Float>, _ material: RealityKit.Material,
                 corner: Float = 0.03, tilt: Float = 0) {
            let part = ModelEntity(mesh: .generateBox(size: size, cornerRadius: corner), materials: [material])
            part.position = position
            if tilt != 0 { part.orientation = simd_quatf(angle: tilt, axis: SIMD3<Float>(1, 0, 0)) }
            root.addChild(part)
        }
        // A cylinder lies along Y; a wheel turns about X.
        func wheel(radius: Float, width: Float, at position: SIMD3<Float>) {
            let part = ModelEntity(mesh: .abloxCylinder(height: width, radius: radius), materials: [dark])
            part.position = position
            part.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            root.addChild(part)
        }
        func fourWheels(radius: Float, width: Float, x: Float, z: Float) {
            for sx in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    wheel(radius: radius, width: width, at: SIMD3<Float>(sx * x, radius, sz * z))
                }
            }
        }
        func lights(x: Float, y: Float, front: Float, back: Float) {
            for sx in [Float(-1), 1] {
                box(SIMD3<Float>(0.34, 0.16, 0.06), at: SIMD3<Float>(sx * x, y, front), lamp, corner: 0.02)
                box(SIMD3<Float>(0.34, 0.14, 0.06), at: SIMD3<Float>(sx * x, y, back), brake, corner: 0.02)
            }
        }

        switch ride {
        case .none:
            return
        case .car:
            box(SIMD3<Float>(1.9, 0.6, 3.6), at: SIMD3<Float>(0, 0.5, 0), paint, corner: 0.14)
            box(SIMD3<Float>(1.7, 0.5, 0.08), at: SIMD3<Float>(0, 1.0, -0.6), glass, tilt: 0.45)
            box(SIMD3<Float>(1.5, 0.45, 0.14), at: SIMD3<Float>(0, 0.95, 0.55), dark)
            fourWheels(radius: 0.36, width: 0.32, x: 0.95, z: 1.15)
            lights(x: 0.6, y: 0.62, front: -1.81, back: 1.81)
        case .sports:
            box(SIMD3<Float>(1.9, 0.45, 4.0), at: SIMD3<Float>(0, 0.42, 0), paint, corner: 0.18)
            box(SIMD3<Float>(1.6, 0.35, 0.08), at: SIMD3<Float>(0, 0.78, -0.5), glass, tilt: 0.7)
            box(SIMD3<Float>(1.8, 0.07, 0.4), at: SIMD3<Float>(0, 0.98, 1.8), paint)
            for sx in [Float(-1), 1] {
                box(SIMD3<Float>(0.08, 0.3, 0.08), at: SIMD3<Float>(sx * 0.7, 0.8, 1.8), dark)
            }
            fourWheels(radius: 0.34, width: 0.34, x: 0.97, z: 1.3)
            lights(x: 0.62, y: 0.5, front: -2.01, back: 2.01)
        case .truck:
            box(SIMD3<Float>(2.2, 0.8, 4.4), at: SIMD3<Float>(0, 0.75, 0), paint, corner: 0.1)
            box(SIMD3<Float>(2.0, 0.6, 0.08), at: SIMD3<Float>(0, 1.45, -0.75), glass, tilt: 0.3)
            box(SIMD3<Float>(2.2, 0.55, 1.8), at: SIMD3<Float>(0, 1.42, 1.25), dark, corner: 0.05)
            fourWheels(radius: 0.5, width: 0.4, x: 1.05, z: 1.5)
            lights(x: 0.72, y: 0.9, front: -2.21, back: 2.21)
        case .kart:
            box(SIMD3<Float>(1.3, 0.3, 2.0), at: SIMD3<Float>(0, 0.3, 0), paint, corner: 0.1)
            box(SIMD3<Float>(1.5, 0.12, 0.2), at: SIMD3<Float>(0, 0.25, -1.05), dark)
            box(SIMD3<Float>(0.8, 0.5, 0.14), at: SIMD3<Float>(0, 0.6, 0.5), dark)
            box(SIMD3<Float>(0.5, 0.06, 0.06), at: SIMD3<Float>(0, 0.72, -0.45), dark)
            fourWheels(radius: 0.25, width: 0.26, x: 0.72, z: 0.72)
        case .bike:
            wheel(radius: 0.35, width: 0.08, at: SIMD3<Float>(0, 0.35, -0.65))
            wheel(radius: 0.35, width: 0.08, at: SIMD3<Float>(0, 0.35, 0.65))
            box(SIMD3<Float>(0.08, 0.08, 1.2), at: SIMD3<Float>(0, 0.62, 0), paint)
            box(SIMD3<Float>(0.06, 0.55, 0.06), at: SIMD3<Float>(0, 0.8, -0.6), paint)
            box(SIMD3<Float>(0.7, 0.06, 0.06), at: SIMD3<Float>(0, 1.08, -0.6), dark)
        case .scooter:
            box(SIMD3<Float>(0.42, 0.08, 1.1), at: SIMD3<Float>(0, 0.2, 0), paint)
            wheel(radius: 0.15, width: 0.1, at: SIMD3<Float>(0, 0.15, -0.5))
            wheel(radius: 0.15, width: 0.1, at: SIMD3<Float>(0, 0.15, 0.5))
            box(SIMD3<Float>(0.07, 1.0, 0.07), at: SIMD3<Float>(0, 0.72, -0.52), paint)
            box(SIMD3<Float>(0.6, 0.06, 0.06), at: SIMD3<Float>(0, 1.2, -0.52), dark)
        case .jetpack:
            box(SIMD3<Float>(0.5, 0.6, 0.25), at: SIMD3<Float>(0, 1.0, 0.32), paint, corner: 0.06)
            for sx in [Float(-1), 1] {
                let nozzle = ModelEntity(mesh: .abloxCylinder(height: 0.25, radius: 0.09), materials: [dark])
                nozzle.position = SIMD3<Float>(sx * 0.14, 0.62, 0.35)
                root.addChild(nozzle)
                box(SIMD3<Float>(0.12, 0.28, 0.12), at: SIMD3<Float>(sx * 0.14, 0.38, 0.35), flame, corner: 0.05)
            }
        case .hoverboard:
            box(SIMD3<Float>(0.8, 0.1, 1.6), at: SIMD3<Float>(0, 0.12, 0), paint, corner: 0.05)
            box(SIMD3<Float>(0.6, 0.02, 1.4), at: SIMD3<Float>(0, 0.05, 0), glow, corner: 0.01)
        }
        addChild(root)
        rideEntity = root
    }

    // MARK: Weapon

    /// Puts a script-given weapon in the right hand, or empties it.
    public func hold(weaponModel model: String?) {
        guard model != heldWeaponModel else { return }
        heldWeapon?.removeFromParent()
        heldWeapon = nil
        heldWeaponModel = model
        guard let model else { return }
        let weapon = WeaponModel.make(model)
        // The hand is the bottom of the arm; the arm's origin is its middle.
        weapon.position = SIMD3<Float>(0, -0.3, -0.1)
        rightArm.addChild(weapon)
        heldWeapon = weapon
    }

    /// Where a shot from this avatar's weapon starts, in world space.
    public var muzzlePosition: Vec3? {
        guard let heldWeapon, let model = heldWeaponModel else { return nil }
        return Vec3(heldWeapon.convert(position: WeaponModel.muzzle(model), to: nil))
    }

    // MARK: Animation

    /// Eases toward the networked target and animates the walk cycle.
    ///
    /// - Parameter smoothing: 0 snaps, 1 never arrives. Remote avatars use a
    ///   frame-rate-independent factor so the easing looks the same at 30 and
    ///   120 Hz.
    public func update(deltaTime: Float, smoothing: Float = 12) {
        let blend = 1 - exp(-smoothing * deltaTime)

        let current = Vec3(position)
        let next = Vec3.lerp(current, targetPosition, blend)
        position = next.simd

        let currentYaw = Quat(orientation).eulerDegrees.y
        let yaw = normalizeDegrees(currentYaw + angularDelta(from: currentYaw, to: targetYawDegrees) * blend)
        orientation = Quat.yaw(degrees: yaw).simd

        let travelled = next.horizontalDistance(to: current)
        animate(travelled: travelled, deltaTime: deltaTime)
    }

    /// The walk cycle, or the gesture playing — for the local avatar too,
    /// which is moved directly rather than eased.
    public func animate(travelled: Float, deltaTime: Float) {
        strideDistance += travelled
        if let petEntity {
            // A small bob, faster while walking; fliers hover.
            petPhase += deltaTime * (travelled > 0.01 ? 12 : 3)
            let bob = appliedPet.flies ? sin(petPhase * 0.5) * 0.08 : abs(sin(petPhase)) * 0.06
            petEntity.position = petHome + SIMD3<Float>(0, bob, 0)
        }
        let speed = travelled / Swift.max(deltaTime, 1e-4)
        if animateGesture(deltaTime: deltaTime, speed: speed) { return }
        animateLimbs(speed: speed)
    }

    // MARK: Gestures

    /// Plays an emote on this avatar. Walking away ends it.
    public func play(_ emote: Emote) {
        resetPose()
        gesture = emote
        gestureTime = 0
    }

    private func resetPose() {
        rig.position = SIMD3<Float>(0, seatHeight, 0)
        rig.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        head.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for (arm, side) in [(leftArm, Float(-1)), (rightArm, Float(1))] {
            arm.position = SIMD3<Float>(side * 0.39, 0.95, 0)
            arm.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        for (leg, side) in [(leftLeg, Float(-1)), (rightLeg, Float(1))] {
            leg.position = SIMD3<Float>(side * 0.16, 0.3, 0)
            leg.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
    }

    /// Poses the limbs for the gesture; false when none is playing.
    private func animateGesture(deltaTime: Float, speed: Float) -> Bool {
        guard let emote = gesture else { return false }
        gestureTime += deltaTime
        // Moving off, or its time is up: back to walking.
        if gestureTime > Float(emote.seconds) || (speed > 1.2 && gestureTime > 0.3) {
            gesture = nil
            resetPose()
            return false
        }
        let t = gestureTime
        let x = SIMD3<Float>(1, 0, 0), z = SIMD3<Float>(0, 0, 1), y = SIMD3<Float>(0, 1, 0)
        /// An arm straight up from the shoulder, tilted `swing` outwards.
        func raise(_ arm: ModelEntity, side: Float, swing: Float = 0) {
            arm.position = SIMD3<Float>(side * (0.42 + abs(swing) * 0.1), 1.5, 0)
            arm.orientation = simd_quatf(angle: side * swing, axis: z)
        }
        func lower(_ arm: ModelEntity, side: Float) {
            arm.position = SIMD3<Float>(side * 0.39, 0.95, 0)
        }
        switch emote {
        case .wave:
            raise(rightArm, side: 1, swing: 0.35 * sin(t * 12))
            lower(leftArm, side: -1)
        case .dance:
            let beat = sin(t * 9)
            rig.position = SIMD3<Float>(0, seatHeight + abs(beat) * 0.12, 0)
            rig.orientation = simd_quatf(angle: sin(t * 4.5) * 0.35, axis: y)
            if beat > 0 { raise(rightArm, side: 1, swing: 0.4); lower(leftArm, side: -1) } else { raise(leftArm, side: -1, swing: 0.4); lower(rightArm, side: 1) }
            leftLeg.orientation = simd_quatf(angle: beat * 0.35, axis: x)
            rightLeg.orientation = simd_quatf(angle: -beat * 0.35, axis: x)
        case .clap:
            let open = (sin(t * 16) + 1) * 0.18
            leftArm.position = SIMD3<Float>(-0.25 - open, 1.05, -0.28)
            rightArm.position = SIMD3<Float>(0.25 + open, 1.05, -0.28)
            leftArm.orientation = simd_quatf(angle: -1.35, axis: x)
            rightArm.orientation = simd_quatf(angle: -1.35, axis: x)
        case .cheer:
            raise(leftArm, side: -1, swing: 0.35)
            raise(rightArm, side: 1, swing: 0.35)
            rig.position = SIMD3<Float>(0, seatHeight + abs(sin(t * 7)) * 0.3, 0)
        case .bow:
            let depth = sin(Swift.min(1, t / Float(emote.seconds)) * .pi) * 0.7
            rig.orientation = simd_quatf(angle: -depth, axis: x)
        case .point:
            rightArm.position = SIMD3<Float>(0.39, 1.2, -0.3)
            rightArm.orientation = simd_quatf(angle: -1.5, axis: x)
        case .laugh:
            head.orientation = simd_quatf(angle: 0.3 + sin(t * 20) * 0.08, axis: x)
            rig.position = SIMD3<Float>(0, seatHeight + abs(sin(t * 18)) * 0.04, 0)
        case .sit:
            rig.position = SIMD3<Float>(0, seatHeight - 0.32, 0)
            for (leg, side) in [(leftLeg, Float(-1)), (rightLeg, Float(1))] {
                leg.position = SIMD3<Float>(side * 0.16, 0.55, -0.25)
                leg.orientation = simd_quatf(angle: -1.45, axis: x)
            }
        }
        return true
    }

    private func animateLimbs(speed: Float) {
        // Below walking pace the limbs settle rather than jitter.
        guard speed > 0.2 else {
            for limb in [leftArm, rightArm, leftLeg, rightLeg] {
                limb.orientation = simd_slerp(limb.orientation, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), 0.2)
            }
            return
        }

        // Phase from distance travelled, so the swing matches the stride
        // instead of drifting when the avatar speeds up or slows down.
        let phase = strideDistance * 3.2
        let swing = sin(phase) * Swift.min(0.6, speed * 0.09)

        leftLeg.orientation = simd_quatf(angle: swing, axis: SIMD3<Float>(1, 0, 0))
        rightLeg.orientation = simd_quatf(angle: -swing, axis: SIMD3<Float>(1, 0, 0))
        leftArm.orientation = simd_quatf(angle: -swing * 0.8, axis: SIMD3<Float>(1, 0, 0))
        rightArm.orientation = simd_quatf(angle: swing * 0.8, axis: SIMD3<Float>(1, 0, 0))
    }

    /// Snaps without easing — used on spawn and after a teleport, where
    /// sliding across the map would look like a bug.
    public func teleport(to newPosition: Vec3, yawDegrees: Float) {
        targetPosition = newPosition
        targetYawDegrees = yawDegrees
        position = newPosition.simd
        orientation = Quat.yaw(degrees: yawDegrees).simd
    }
}
