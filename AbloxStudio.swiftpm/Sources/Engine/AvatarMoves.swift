import Foundation
import RealityKit
import simd
import UIKit
import AbloxCore

// The newer emotes, looking about when stood still, the pet joining in, and
// the ring of light round the feet. Kept apart from `AvatarEntity` so each
// piece is compiled on its own; one pose per function, as there.
extension AvatarEntity {

    // MARK: Newer emotes

    func poseNewer(_ emote: Emote, _ t: Float) {
        switch emote {
        case .hop: poseHop(t)
        case .spin: poseSpin(t)
        case .flex: poseFlex(t)
        case .shrug: poseShrug(t)
        case .think: poseThink(t)
        case .facepalm: poseFacepalm(t)
        case .salute: poseSalute()
        case .thumbsUp: poseThumbsUp(t)
        case .heartHands: poseHeartHands(t)
        case .yawn: poseYawn(t)
        case .stretch: poseStretch(t)
        case .dab: poseDab()
        case .floss: poseFloss(t)
        case .robot: poseRobot(t)
        case .flip: poseFlip(t)
        case .cry: poseCry(t)
        case .stomp: poseStomp(t)
        case .victory: poseVictory(t)
        case .guitar: poseGuitar(t)
        case .peace: posePeace(t)
        case .wave, .dance, .clap, .cheer, .bow, .point, .laugh, .sit: break
        }
    }

    /// An arm held straight out to the side.
    private func outwards(_ arm: ModelEntity, side: Float, lift: Float = 0) {
        arm.position = SIMD3<Float>(side * 0.62, 1.2 + lift, 0)
        arm.orientation = simd_quatf(angle: side * .pi / 2, axis: Self.forwards)
    }

    /// An arm reaching forward and up, the hand at `to`.
    private func reach(_ arm: ModelEntity, to point: SIMD3<Float>, angle: Float) {
        arm.position = point
        arm.orientation = simd_quatf(angle: angle, axis: Self.sideways)
    }

    private func poseHop(_ t: Float) {
        let lift: Float = abs(sin(t * 6)) * 0.45
        rig.position = SIMD3<Float>(0, seatHeight + lift, 0)
        raise(leftArm, side: -1, swing: 0.5)
        raise(rightArm, side: 1, swing: 0.5)
    }

    private func poseSpin(_ t: Float) {
        rig.orientation = simd_quatf(angle: t * 8, axis: Self.upright)
        outwards(leftArm, side: -1)
        outwards(rightArm, side: 1)
    }

    private func poseFlex(_ t: Float) {
        let pulse: Float = sin(t * 8) * 0.05
        raise(leftArm, side: -1, swing: 1.1 + pulse)
        raise(rightArm, side: 1, swing: 1.1 + pulse)
        rig.position = SIMD3<Float>(0, seatHeight + abs(pulse), 0)
    }

    private func poseShrug(_ t: Float) {
        let up: Float = Swift.min(1, t * 4) * 0.1
        for (arm, side) in [(leftArm, Float(-1)), (rightArm, Float(1))] {
            arm.position = SIMD3<Float>(side * 0.45, 0.95 + up, -0.05)
            arm.orientation = simd_quatf(angle: side * 0.45, axis: Self.forwards)
        }
        head.orientation = simd_quatf(angle: 0.2, axis: Self.forwards)
    }

    private func poseThink(_ t: Float) {
        reach(rightArm, to: SIMD3<Float>(0.22, 1.24, -0.2), angle: -2.2)
        head.orientation = simd_quatf(angle: 0.15 + sin(t * 2) * 0.05, axis: Self.forwards)
    }

    private func poseFacepalm(_ t: Float) {
        reach(rightArm, to: SIMD3<Float>(0.12, 1.34, -0.24), angle: -2.6)
        head.orientation = simd_quatf(angle: 0.3 + sin(t * 3) * 0.04, axis: Self.sideways)
    }

    private func poseSalute() {
        reach(rightArm, to: SIMD3<Float>(0.3, 1.46, -0.1), angle: -2.4)
    }

    private func poseThumbsUp(_ t: Float) {
        reach(rightArm, to: SIMD3<Float>(Self.shoulderX, 1.15, -0.3), angle: -1.4)
        rig.position = SIMD3<Float>(0, seatHeight + abs(sin(t * 5)) * 0.05, 0)
    }

    private func poseHeartHands(_ t: Float) {
        let sway: Float = sin(t * 3) * 0.1
        leftArm.position = SIMD3<Float>(-0.22, 1.5, -0.2)
        rightArm.position = SIMD3<Float>(0.22, 1.5, -0.2)
        leftArm.orientation = simd_quatf(angle: -0.7, axis: Self.forwards)
        rightArm.orientation = simd_quatf(angle: 0.7, axis: Self.forwards)
        rig.orientation = simd_quatf(angle: sway, axis: Self.forwards)
    }

    private func poseYawn(_ t: Float) {
        let open: Float = sin(Swift.min(1, t / 3) * .pi)
        raise(leftArm, side: -1, swing: 0.3 * open)
        raise(rightArm, side: 1, swing: 0.3 * open)
        head.orientation = simd_quatf(angle: -0.35 * open, axis: Self.sideways)
    }

    private func poseStretch(_ t: Float) {
        raise(leftArm, side: -1, swing: 0.1)
        raise(rightArm, side: 1, swing: 0.1)
        rig.orientation = simd_quatf(angle: sin(t * 2.2) * 0.25, axis: Self.forwards)
    }

    private func poseDab() {
        raise(rightArm, side: 1, swing: 0.9)
        reach(leftArm, to: SIMD3<Float>(-0.05, 1.42, -0.26), angle: -1.9)
        head.orientation = simd_quatf(angle: 0.4, axis: Self.sideways)
    }

    private func poseFloss(_ t: Float) {
        let swing: Float = sin(t * 10)
        for (arm, side) in [(leftArm, Float(-1)), (rightArm, Float(1))] {
            arm.position = SIMD3<Float>(side * Self.shoulderX + swing * 0.18, 0.9, swing * side * 0.15)
            arm.orientation = simd_quatf(angle: swing * 0.4, axis: Self.forwards)
        }
        rig.orientation = simd_quatf(angle: -swing * 0.15, axis: Self.upright)
    }

    private func poseRobot(_ t: Float) {
        // Stiff, in steps.
        let step: Float = (sin(t * 5) > 0) ? 1 : -1
        reach(leftArm, to: SIMD3<Float>(-Self.shoulderX, 1.15, -0.3), angle: step > 0 ? -1.5 : 0)
        reach(rightArm, to: SIMD3<Float>(Self.shoulderX, 1.15, -0.3), angle: step > 0 ? 0 : -1.5)
        if step < 0 { lower(leftArm, side: -1) } else { lower(rightArm, side: 1) }
        head.orientation = simd_quatf(angle: step * 0.4, axis: Self.upright)
    }

    private func poseFlip(_ t: Float) {
        let progress: Float = Swift.min(1, t / 1.2)
        let lift: Float = sin(progress * .pi) * 0.9
        rig.position = SIMD3<Float>(0, seatHeight + lift + 0.5 * sin(progress * .pi), 0)
        rig.orientation = simd_quatf(angle: -progress * 2 * .pi, axis: Self.sideways)
    }

    private func poseCry(_ t: Float) {
        reach(leftArm, to: SIMD3<Float>(-0.12, 1.3, -0.24), angle: -2.5)
        reach(rightArm, to: SIMD3<Float>(0.12, 1.3, -0.24), angle: -2.5)
        head.orientation = simd_quatf(angle: 0.35, axis: Self.sideways)
        rig.position = SIMD3<Float>(sin(t * 30) * 0.015, seatHeight, 0)
    }

    private func poseStomp(_ t: Float) {
        let beat: Float = sin(t * 9)
        leftLeg.position = SIMD3<Float>(-Self.hipX, 0.3 + Swift.max(0, beat) * 0.2, 0)
        rightLeg.position = SIMD3<Float>(Self.hipX, 0.3 + Swift.max(0, -beat) * 0.2, 0)
        lower(leftArm, side: -1)
        lower(rightArm, side: 1)
        leftArm.orientation = simd_quatf(angle: -0.3, axis: Self.forwards)
        rightArm.orientation = simd_quatf(angle: 0.3, axis: Self.forwards)
    }

    private func poseVictory(_ t: Float) {
        raise(rightArm, side: 1, swing: 0)
        lower(leftArm, side: -1)
        rig.position = SIMD3<Float>(0, seatHeight + abs(sin(t * 6)) * 0.3, 0)
        rig.orientation = simd_quatf(angle: t * 2.5, axis: Self.upright)
    }

    private func poseGuitar(_ t: Float) {
        reach(leftArm, to: SIMD3<Float>(-0.45, 1.1, -0.3), angle: -1.2)
        let strum: Float = sin(t * 18) * 0.25
        reach(rightArm, to: SIMD3<Float>(0.12, 0.95, -0.25), angle: -1.0 + strum)
        head.orientation = simd_quatf(angle: abs(sin(t * 9)) * 0.3, axis: Self.sideways)
    }

    private func posePeace(_ t: Float) {
        reach(rightArm, to: SIMD3<Float>(0.3, 1.5, -0.18), angle: -2.8)
        head.orientation = simd_quatf(angle: -0.18, axis: Self.forwards)
        rig.position = SIMD3<Float>(0, seatHeight + abs(sin(t * 4)) * 0.04, 0)
    }

    // MARK: Stood still

    /// After a few seconds without moving, a slow look to one side and the
    /// other, so a waiting avatar does not look frozen.
    func lookAbout(speed: Float, deltaTime: Float) {
        guard speed <= 0.2 else {
            if idleTime > 5 { head.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
            idleTime = 0
            return
        }
        idleTime += deltaTime
        guard idleTime > 5 else { return }
        let look: Float = sin((idleTime - 5) * 0.7) * 0.4
        head.orientation = simd_quatf(angle: look, axis: Self.upright)
    }

    // MARK: The pet joins in

    /// Height of the pet's little jump when its owner emotes; it turns too.
    func petTrickLift(deltaTime: Float) -> Float {
        guard petTrick > 0, let petEntity else { return 0 }
        petTrick = Swift.max(0, petTrick - deltaTime)
        let progress: Float = 1 - petTrick / 0.9
        petEntity.orientation = simd_quatf(angle: progress * 2 * .pi, axis: Self.upright)
        if petTrick == 0 { petEntity.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return sin(progress * .pi) * 0.3
    }

    // MARK: Aura

    func applyAura(_ aura: AvatarProfile.Aura) {
        guard aura != appliedAura else { return }
        appliedAura = aura
        auraEntity?.removeFromParent()
        auraEntity = nil
        auraOrbs = []
        auraMaterials = []
        guard aura != .none else { return }
        auraMaterials = aura.colors.map { colour in
            UnlitMaterial(color: UIColor(red: CGFloat(colour.r), green: CGFloat(colour.g), blue: CGFloat(colour.b), alpha: 1))
        }
        guard let first = auraMaterials.first else { return }
        let root = Entity()
        root.name = "ablox.avatar.aura"
        // A ring of short glowing pieces just off the ground: open in the
        // middle, so the floor shows through.
        let ring = Entity()
        let pieces = 20
        for index in 0..<pieces {
            let angle: Float = Float(index) / Float(pieces) * 2 * .pi
            let piece = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.17, 0.02, 0.05)), materials: [first])
            piece.position = SIMD3<Float>(cos(angle) * 0.58, 0.02, sin(angle) * 0.58)
            piece.orientation = simd_quatf(angle: -angle + .pi / 2, axis: Self.upright)
            ring.addChild(piece)
        }
        root.addChild(ring)
        for index in 0..<aura.orbs {
            let orb = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [auraMaterials[index % auraMaterials.count]])
            root.addChild(orb)
            auraOrbs.append(orb)
        }
        addChild(root)
        auraEntity = root
    }

    /// Turns the ring, circles the lights, and steps through the colours.
    func animateAura(deltaTime: Float) {
        guard let auraEntity else { return }
        auraTime += deltaTime
        auraEntity.orientation = simd_quatf(angle: auraTime * 0.8, axis: Self.upright)
        for (index, orb) in auraOrbs.enumerated() {
            let angle: Float = auraTime * 2 + Float(index) / Float(Swift.max(1, auraOrbs.count)) * 2 * .pi
            let height: Float = 0.4 + sin(auraTime * 3 + Float(index)) * 0.3
            orb.position = SIMD3<Float>(cos(angle) * 0.55, height, sin(angle) * 0.55)
        }
        // A new colour three times a second, and only when it changes.
        guard auraMaterials.count > 1, let ring = auraEntity.children.first else { return }
        let index = Int(auraTime * 3) % auraMaterials.count
        let before = Int(Swift.max(0, auraTime - deltaTime) * 3) % auraMaterials.count
        guard index != before else { return }
        for case let piece as ModelEntity in ring.children {
            piece.model?.materials = [auraMaterials[index]]
        }
    }
}
