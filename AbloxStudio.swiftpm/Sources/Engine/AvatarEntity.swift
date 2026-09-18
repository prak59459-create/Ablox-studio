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

    private let body = ModelEntity()
    private let head = ModelEntity()
    private let leftArm = ModelEntity()
    private let rightArm = ModelEntity()
    private let leftLeg = ModelEntity()
    private let rightLeg = ModelEntity()
    private var hatEntity: ModelEntity?

    /// Where the network says this avatar is. The entity eases toward it
    /// rather than snapping, which hides the 15 Hz transform rate.
    public var targetPosition: Vec3
    public var targetYawDegrees: Float

    /// Accumulated distance walked, used to phase the limb swing so the walk
    /// cycle is tied to movement rather than to wall-clock time.
    private var strideDistance: Float = 0

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
            addChild(part)
        }
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

        applyHat(profile.hat, material: accentMaterial)
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
            mesh = .generateCylinder(height: 0.2, radius: 0.26)
            offset = SIMD3<Float>(0, 1.86, 0)
        case .antenna:
            mesh = .generateCylinder(height: 0.5, radius: 0.03)
            offset = SIMD3<Float>(0, 2.0, 0)
        case .halo:
            mesh = .generateCylinder(height: 0.04, radius: 0.32)
            offset = SIMD3<Float>(0, 2.05, 0)
        }

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = offset
        entity.name = "ablox.avatar.hat"
        addChild(entity)
        hatEntity = entity
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
        strideDistance += travelled
        animateLimbs(speed: travelled / Swift.max(deltaTime, 1e-4))
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
