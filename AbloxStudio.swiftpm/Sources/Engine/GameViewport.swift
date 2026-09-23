import SwiftUI
import RealityKit
import ARKit
import simd
import Combine

/// The 3D play surface: a non-AR `ARView` driving the world, the local
/// avatar, and everyone else's.
///
/// `ARView` in `.nonAR` mode rather than `RealityView` so the app runs on
/// iPadOS 17 as well as 18, and because `ARView` exposes the render-loop hook
/// (`scene.subscribe(to: SceneEvents.Update.self)`) that the character
/// controller needs.
public struct GameViewport: UIViewRepresentable {

    @ObservedObject var session: SessionCoordinator
    @Binding var input: MovementInput
    /// Camera orbit, driven by dragging on the right half of the screen.
    @Binding var cameraYaw: Float
    @Binding var cameraPitch: Float
    var onBlockTapped: ((UUID) -> Void)?
    /// Mirrors the Settings toggles, which had nothing to switch off until
    /// sound existed.
    var soundEnabled: Bool
    var hapticsEnabled: Bool
    /// The fire button is held. Shots go out at the weapon's rate while it is.
    var isFiring: Bool

    public init(
        session: SessionCoordinator,
        input: Binding<MovementInput>,
        cameraYaw: Binding<Float>,
        cameraPitch: Binding<Float>,
        soundEnabled: Bool = true,
        hapticsEnabled: Bool = true,
        isFiring: Bool = false,
        onBlockTapped: ((UUID) -> Void)? = nil
    ) {
        self.session = session
        self._input = input
        self._cameraYaw = cameraYaw
        self._cameraPitch = cameraPitch
        self.soundEnabled = soundEnabled
        self.hapticsEnabled = hapticsEnabled
        self.isFiring = isFiring
        self.onBlockTapped = onBlockTapped
    }

    public func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(
            red: CGFloat(session.world.environment.skyBottom.r),
            green: CGFloat(session.world.environment.skyBottom.g),
            blue: CGFloat(session.world.environment.skyBottom.b),
            alpha: 1
        ))
        // Ablox draws its own selection affordances; RealityKit's debug
        // options and default gestures would fight them.
        view.renderOptions.insert(.disableMotionBlur)

        context.coordinator.attach(to: view)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    public func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.setFeedbackEnabled(sound: soundEnabled, haptics: hapticsEnabled)
        context.coordinator.syncWorld(session.world)
        context.coordinator.syncRoster(session.roster, localPeerID: session.localPeerID)
        // Effects are drained in the render loop, not here: `drainEffects()`
        // mutates published state, and doing that inside `updateUIView` means
        // changing SwiftUI state while SwiftUI is mid-update.
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator {
        var parent: GameViewport

        private let worldScene = WorldScene()
        private let cameraAnchor = AnchorEntity(world: .zero)
        private let camera = PerspectiveCamera()

        private var avatars: [PeerID: AvatarEntity] = [:]
        private var localAvatar: AvatarEntity?

        private weak var view: ARView?
        private var updateSubscription: Cancellable?

        /// Local player state, simulated here and published to the network.
        private var localSnapshot: PlayerSnapshot
        /// Decides which ticks are worth a packet — see `TransformPublisher`.
        private var publisher = TransformPublisher()
        private var elapsed: TimeInterval = 0
        /// Sound and haptics. `playSound` effects have been arriving and going
        /// nowhere since the first phase; this is what finally plays them.
        private let feedback = FeedbackPlayer()
        private var lastWorldRevision: Date?

        /// Blocks currently overlapped, so a touch is reported on entry rather
        /// than every frame the player stands there.
        private var currentlyTouching: Set<UUID> = []

        // MARK: Script-driven play

        /// Where the camera looks, kept for aiming.
        private var viewDirection = Vec3(0, 0, -1)
        /// The weapon drawn at the bottom of a first-person view.
        private var viewModel: Entity?
        private var viewModelKind: String?
        private var lastShotTime: Double = -.infinity
        /// 1 just after a shot, easing to 0: the view model's kick.
        private var recoil: Float = 0
        /// Shot lines, which fade in a tenth of a second.
        private var tracers: [(entity: ModelEntity, age: Float)] = []
        private var lastSky: ColorRGBA?
        private var shakeSerial = 0
        private var shakeRemaining: Float = 0
        private var shakeStrength: Float = 0

        init(parent: GameViewport) {
            self.parent = parent
            self.localSnapshot = PlayerSnapshot(
                peerID: parent.session.localPeerID,
                profile: parent.session.profile,
                position: parent.session.world.spawnPosition(forPlayerIndex: 0)
            )
        }

        func attach(to view: ARView) {
            self.view = view

            view.scene.addAnchor(worldScene.anchor)

            camera.camera.fieldOfViewInDegrees = 65
            cameraAnchor.addChild(camera)
            view.scene.addAnchor(cameraAnchor)

            feedback.prepare()

            let local = AvatarEntity(
                peerID: parent.session.localPeerID,
                profile: parent.session.profile,
                position: localSnapshot.position
            )
            worldScene.anchor.addChild(local)
            localAvatar = local

            updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                // Scene updates are delivered on the main thread, but the
                // closure itself is non-isolated, so the hop has to be stated
                // for the compiler rather than assumed.
                MainActor.assumeIsolated {
                    self?.tick(deltaTime: Float(event.deltaTime))
                }
            }
        }

        func setFeedbackEnabled(sound: Bool, haptics: Bool) {
            feedback.isSoundEnabled = sound
            feedback.isHapticsEnabled = haptics
        }

        func detach() {
            updateSubscription?.cancel()
            updateSubscription = nil
            worldScene.removeAll()
            avatars.removeAll()
        }

        // MARK: Sync

        func syncWorld(_ world: WorldDocument) {
            // `modifiedAt` is the cheap revision check; a full diff of every
            // block on every SwiftUI update would be wasteful, and WorldScene
            // does its own per-block diffing anyway.
            guard world.modifiedAt != lastWorldRevision else { return }
            lastWorldRevision = world.modifiedAt
            worldScene.sync(to: world, physicsEnabled: true)

            // A script can repaint the sky mid-game.
            let sky = world.environment.skyBottom
            if sky != lastSky {
                lastSky = sky
                view?.environment.background = .color(UIColor(
                    red: CGFloat(sky.r), green: CGFloat(sky.g), blue: CGFloat(sky.b), alpha: 1
                ))
            }
        }

        func syncRoster(_ roster: [PlayerSnapshot], localPeerID: PeerID) {
            var seen = Set<PeerID>()

            for player in roster where player.peerID != localPeerID {
                seen.insert(player.peerID)
                if let existing = avatars[player.peerID] {
                    existing.targetPosition = player.position
                    existing.targetYawDegrees = player.yawDegrees
                    if existing.profile != player.profile {
                        existing.apply(profile: player.profile)
                    }
                    existing.isEnabled = !player.isHidden
                } else {
                    let avatar = AvatarEntity(peerID: player.peerID, profile: player.profile, position: player.position)
                    avatar.isEnabled = !player.isHidden
                    worldScene.anchor.addChild(avatar)
                    avatars[player.peerID] = avatar
                }
            }

            for (peerID, avatar) in avatars where !seen.contains(peerID) {
                avatar.removeFromParent()
                avatars.removeValue(forKey: peerID)
            }

            // As the host last said: a script may have recoloured or resized
            // us, and we should see it too.
            let appearance = parent.session.localAppearance
            if let local = localAvatar, local.profile != appearance {
                local.apply(profile: appearance)
            }
        }

        func apply(effects: [EventAction]) {
            for effect in effects {
                switch effect {
                case let .teleportPlayer(destination):
                    localSnapshot.position = destination
                    localSnapshot.velocity = .zero
                    localAvatar?.teleport(to: destination, yawDegrees: localSnapshot.yawDegrees)
                    // Clear the touch set: the blocks we were standing in are
                    // no longer under us, and they must be able to fire again.
                    currentlyTouching.removeAll()
                    // A teleport is exactly the discontinuity dead reckoning
                    // cannot predict, so tell peers immediately.
                    publisher.reset()

                case let .bouncePlayer(speed):
                    // Replaces upward velocity rather than adding to it, so
                    // bouncing mid-rise cannot compound into an escape from
                    // the world.
                    localSnapshot.velocity = Vec3(
                        localSnapshot.velocity.x,
                        speed,
                        localSnapshot.velocity.z
                    )
                    localSnapshot.isGrounded = false
                    publisher.reset()
                case let .playSound(name):
                    feedback.play(named: name)
                case let .script(scriptEffect):
                    // Most of what a script sends is state the session has
                    // already folded into `scripted`. These act on the body.
                    switch scriptEffect {
                    case let .tracer(from, to):
                        spawnTracer(from: from, to: to)
                    case let .launch(velocity):
                        localSnapshot.velocity = velocity
                        localSnapshot.isGrounded = false
                        publisher.reset()
                    case let .face(yaw):
                        localSnapshot.yawDegrees = yaw
                        // The camera turns with them, or the next frame's
                        // "face where the camera looks" would undo it.
                        parent.cameraYaw = -yaw
                        publisher.reset()
                    case let .shake(strength, seconds):
                        shakeStrength = strength
                        shakeRemaining = Float(seconds)
                    default:
                        break
                    }
                default:
                    worldScene.apply(effect: effect)
                }
            }
        }

        // MARK: Render loop

        private func tick(deltaTime: Float) {
            let world = parent.session.world
            let dt = min(deltaTime, 1.0 / 20)
            elapsed += Double(dt)

            // 1. Intent → velocity, scaled by whatever the script allows.
            let scripted = parent.session.scripted
            let scale = scripted.movement
            var input = parent.input
            input.cameraYawDegrees = parent.cameraYaw
            if scale.frozen {
                input.stick = .zero
                input.isJumping = false
            }
            var movement = MovementConfig.default
            movement.walkSpeed *= scale.speed
            movement.jumpSpeed *= scale.jump
            // The world's gravity (Earth's by default) times the player's own.
            let worldGravity = world.environment.gravity / -9.81
            movement.gravity *= scale.gravity * (worldGravity.isFinite ? max(0, min(5, worldGravity)) : 1)
            let motion = CharacterSolver.step(snapshot: localSnapshot, input: input, config: movement, deltaTime: dt)
            localSnapshot.velocity = motion.velocity
            localSnapshot.yawDegrees = motion.yawDegrees
            if scripted.camera.mode == .firstPerson || scripted.weapon != nil {
                // Aiming: the body faces where the camera looks, so walking
                // sideways strafes instead of turning away from the target.
                let forward = Quat.yaw(degrees: parent.cameraYaw).act(Vec3(0, 0, -1))
                localSnapshot.yawDegrees = atan2(forward.x, -forward.z) * 180 / .pi
            }

            // 2. Velocity → position, resolved against the world.
            //    Deterministic and shared with the host — see WorldCollider.
            let size = parent.session.localAppearance.height
            let collision = WorldCollider.resolve(
                position: localSnapshot.position,
                velocity: localSnapshot.velocity,
                body: CharacterBody(radius: 0.4 * size, height: 1.8 * size),
                world: world,
                deltaTime: dt
            )
            localSnapshot.position = collision.position
            localSnapshot.velocity = collision.velocity
            localSnapshot.isGrounded = collision.isGrounded

            // 3. Report newly touched blocks once each, on entry.
            let touchedNow = Set(collision.touchedBlockIDs)
            for blockID in touchedNow.subtracting(currentlyTouching) {
                parent.session.report(blockID: blockID, cause: .touched)
            }
            currentlyTouching = touchedNow

            // 4. Drive the local avatar directly — no easing, it is ours.
            localAvatar?.teleport(to: localSnapshot.position, yawDegrees: localSnapshot.yawDegrees)

            // 5. Ease everyone else toward their last known transform.
            for avatar in avatars.values {
                avatar.update(deltaTime: dt)
            }

            // 6. Apply anything the host told us to do since the last frame.
            let effects = parent.session.drainEffects()
            if !effects.isEmpty { apply(effects: effects) }

            updateCamera(dt: dt)
            updateWeapons(dt: dt)
            if parent.isFiring { fireIfReady() }
            fadeTracers(dt: dt)
            publishIfDue()
        }

        /// The camera the world's script asked for: behind the player (the
        /// default, pulled in when a wall is in the way), at their eyes,
        /// looking down from above, or fixed in the world.
        private func updateCamera(dt: Float) {
            let settings = parent.session.scripted.camera
            let size = parent.session.localAppearance.height
            camera.camera.fieldOfViewInDegrees = max(10, min(150, settings.fieldOfView))

            // A shake is a small random offset that dies away.
            var jitter = Vec3.zero
            if shakeRemaining > 0 {
                shakeRemaining -= dt
                let amount = shakeStrength * max(0, min(1, shakeRemaining * 3)) * 0.25
                jitter = Vec3(Float.random(in: -amount...amount), Float.random(in: -amount...amount), Float.random(in: -amount...amount))
            }

            let hidden = parent.session.localPlayer?.isHidden ?? false
            // Your own head would fill a first-person screen.
            localAvatar?.isEnabled = settings.mode != .firstPerson && !hidden

            switch settings.mode {
            case .firstPerson:
                let pitch = max(-80, min(80, parent.cameraPitch))
                let look = Quat.euler(degrees: Vec3(pitch, parent.cameraYaw, 0)).act(Vec3(0, 0, -1))
                let eye = localSnapshot.position + Vec3(0, PlayerHitBody.eyeHeight * size, 0) + jitter
                // No easing: in first person any lag between thumb and view
                // reads as the game being slow.
                cameraAnchor.position = eye.simd
                camera.look(at: (eye + look).simd, from: eye.simd, relativeTo: nil)
                viewDirection = look
                return

            case .topDown:
                let focus = localSnapshot.position + Vec3(0, 1 * size, 0)
                // Tipped slightly, and turned with the camera yaw, so "up" on
                // the stick is still "away from the camera".
                let offset = Quat.yaw(degrees: parent.cameraYaw).act(Vec3(0, settings.distance, settings.distance * 0.3))
                let eye = focus + offset + jitter
                cameraAnchor.position = Vec3.lerp(Vec3(cameraAnchor.position), eye, 1 - exp(-12 * dt)).simd
                camera.look(at: focus.simd, from: cameraAnchor.position, relativeTo: nil)
                viewDirection = (focus - Vec3(cameraAnchor.position)).normalized
                return

            case .fixed:
                let eye = (settings.position ?? localSnapshot.position + Vec3(0, 5, 8)) + jitter
                let target = settings.target ?? localSnapshot.position + Vec3(0, 1 * size, 0)
                cameraAnchor.position = eye.simd
                if (target - eye).lengthSquared > 1e-4 {
                    camera.look(at: target.simd, from: eye.simd, relativeTo: nil)
                    viewDirection = (target - eye).normalized
                }
                return

            case .thirdPerson:
                break
            }

            let pitch = max(-75, min(20, parent.cameraPitch))
            let orbit = Quat.euler(degrees: Vec3(pitch, parent.cameraYaw, 0))

            let focus = localSnapshot.position + Vec3(0, 1.4 * size, 0) + jitter
            let desiredDistance: Float = settings.distance
            let offset = orbit.act(Vec3(0, 0, 1)) * desiredDistance

            // Keep the camera out of geometry: if the line from the player to
            // the camera crosses a block, sit just in front of it.
            var distance = desiredDistance
            let ray = Ray(origin: focus, direction: offset)
            for block in parent.session.world.blocks where block.hasCollision && block.isVisible {
                guard let bounds = parent.session.world.worldBounds(of: block.id) else { continue }
                if let hit = ray.intersects(bounds.expanded(by: 0.25)), hit < distance {
                    distance = max(1.5, hit)
                }
            }

            let target = focus + orbit.act(Vec3(0, 0, 1)) * distance
            let current = Vec3(cameraAnchor.position)
            // Ease toward the target so wall-clipping corrections do not snap.
            cameraAnchor.position = Vec3.lerp(current, target, 1 - exp(-14 * dt)).simd
            camera.look(at: focus.simd, from: cameraAnchor.position, relativeTo: nil)
            let looking = focus - Vec3(cameraAnchor.position)
            if looking.lengthSquared > 1e-4 { viewDirection = looking.normalized }
        }

        // MARK: Weapons

        /// Puts the script's weapon in the local avatar's hand, and at the
        /// bottom of the screen in first person.
        private func updateWeapons(dt: Float) {
            let scripted = parent.session.scripted
            let model = scripted.weapon?.model
            localAvatar?.hold(weaponModel: model)

            let wanted = scripted.camera.mode == .firstPerson ? model : nil
            if wanted != viewModelKind {
                viewModel?.removeFromParent()
                viewModel = nil
                viewModelKind = wanted
                if let wanted {
                    let weapon = WeaponModel.make(wanted)
                    camera.addChild(weapon)
                    viewModel = weapon
                }
            }

            recoil = max(0, recoil - dt * 9)
            if let viewModel {
                // Lower right, like every shooter; knocked back by each shot.
                viewModel.position = SIMD3<Float>(0.2, -0.2 + recoil * 0.02, -0.42 + recoil * 0.06)
                viewModel.orientation = simd_quatf(angle: recoil * 0.12, axis: SIMD3<Float>(1, 0, 0))
            }
        }

        /// Sends a shot when the weapon is ready. Only a request: the host
        /// checks the rate, the ammo and where we are, and decides the hit.
        private func fireIfReady() {
            let scripted = parent.session.scripted
            guard scripted.canFire, let weapon = scripted.weapon else { return }
            let interval = 1 / max(weapon.fireRate, 0.2)
            guard elapsed - lastShotTime >= interval else { return }
            lastShotTime = elapsed
            recoil = 1

            let eyes = localSnapshot.position + Vec3(0, PlayerHitBody.eyeHeight * parent.session.localAppearance.height, 0)
            parent.session.send(input: .fire(origin: eyes, direction: aimDirection(from: eyes, range: weapon.range)))
        }

        /// The shot leaves the eyes but must land under the crosshair, which
        /// in third person sits on a ray from the camera several metres
        /// behind them. So: find what the crosshair is on, then aim at that.
        private func aimDirection(from eyes: Vec3, range: Float) -> Vec3 {
            let world = parent.session.world
            let origin = Vec3(camera.position(relativeTo: nil))
            let blocks: [(id: UUID, bounds: BoundingBox)] = world.blocks.compactMap { block in
                guard block.isVisible, block.hasCollision, let bounds = world.worldBounds(of: block.id) else { return nil }
                return (block.id, bounds)
            }
            let players: [(peer: PeerID, position: Vec3)] = avatars.map { ($0.key, $0.value.targetPosition) }
            let crosshair = Hitscan.cast(
                from: origin, direction: viewDirection, range: range + origin.distance(to: eyes),
                shooter: parent.session.localPeerID, players: players, blocks: blocks
            )
            let direction = crosshair.point - eyes
            // Something right in front of the camera but behind the eyes
            // would flip the shot round; fall back to the view direction.
            guard direction.lengthSquared > 0.25, direction.normalized.dot(viewDirection) > 0 else { return viewDirection }
            return direction.normalized
        }

        private func spawnTracer(from start: Vec3, to end: Vec3) {
            var from = start
            // Our own shot starts at our eyes, which in first person is the
            // camera — a line straight away from the viewer is invisible.
            // Draw it from the gun instead.
            let eyes = localSnapshot.position + Vec3(0, PlayerHitBody.eyeHeight * parent.session.localAppearance.height, 0)
            if start.distance(to: eyes) < 0.8 {
                if let viewModel, let kind = viewModelKind {
                    from = Vec3(viewModel.convert(position: WeaponModel.muzzle(kind), to: nil))
                } else if let muzzle = localAvatar?.muzzlePosition {
                    from = muzzle
                }
            }

            let length = from.distance(to: end)
            guard length > 0.05 else { return }
            if tracers.count >= 32, let oldest = tracers.first {
                oldest.entity.removeFromParent()
                tracers.removeFirst()
            }
            let line = ModelEntity(
                mesh: .generateBox(size: SIMD3<Float>(0.03, 0.03, length)),
                materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.86, blue: 0.35, alpha: 1))]
            )
            // Parented first, so "relative to nothing" means the world the
            // line is actually in.
            worldScene.anchor.addChild(line)
            line.look(at: end.simd, from: ((from + end) * 0.5).simd, relativeTo: nil)
            tracers.append((line, 0))
        }

        private func fadeTracers(dt: Float) {
            guard !tracers.isEmpty else { return }
            for index in tracers.indices {
                tracers[index].age += dt
            }
            for tracer in tracers where tracer.age > 0.12 {
                tracer.entity.removeFromParent()
            }
            tracers.removeAll { $0.age > 0.12 }
        }

        /// Publishes only when peers could not have predicted where we are.
        ///
        /// The rate ceiling lives inside `TransformPublisher` along with the
        /// thresholds, so this is just "ask, then send" — and a player who is
        /// standing still costs one keepalive a second instead of twenty
        /// packets.
        private func publishIfDue() {
            guard publisher.shouldPublish(localSnapshot, at: elapsed) else { return }
            parent.session.publishLocalTransform(localSnapshot)
        }

        // MARK: Interaction

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let location = recognizer.location(in: view)
            guard let entity = view.entity(at: location),
                  let blockID = worldScene.blockID(forHit: entity) else { return }

            parent.session.report(blockID: blockID, cause: .tapped)
            parent.onBlockTapped?(blockID)
        }

        /// Moves the local player to a spawn point. Called when a round starts.
        func respawn(in world: WorldDocument, index: Int) {
            let spawn = world.spawnPosition(forPlayerIndex: index)
            localSnapshot.position = spawn
            localSnapshot.velocity = .zero
            currentlyTouching.removeAll()
            localAvatar?.teleport(to: spawn, yawDegrees: 0)
        }
    }
}

#if canImport(QuartzCore)
import QuartzCore
#endif
