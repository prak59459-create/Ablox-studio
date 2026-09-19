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

    public init(
        session: SessionCoordinator,
        input: Binding<MovementInput>,
        cameraYaw: Binding<Float>,
        cameraPitch: Binding<Float>,
        soundEnabled: Bool = true,
        hapticsEnabled: Bool = true,
        onBlockTapped: ((UUID) -> Void)? = nil
    ) {
        self.session = session
        self._input = input
        self._cameraYaw = cameraYaw
        self._cameraPitch = cameraPitch
        self.soundEnabled = soundEnabled
        self.hapticsEnabled = hapticsEnabled
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
                } else {
                    let avatar = AvatarEntity(peerID: player.peerID, profile: player.profile, position: player.position)
                    worldScene.anchor.addChild(avatar)
                    avatars[player.peerID] = avatar
                }
            }

            for (peerID, avatar) in avatars where !seen.contains(peerID) {
                avatar.removeFromParent()
                avatars.removeValue(forKey: peerID)
            }

            if let local = localAvatar, local.profile != parent.session.profile {
                local.apply(profile: parent.session.profile)
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

            // 1. Intent → velocity.
            var input = parent.input
            input.cameraYawDegrees = parent.cameraYaw
            let motion = CharacterSolver.step(snapshot: localSnapshot, input: input, deltaTime: dt)
            localSnapshot.velocity = motion.velocity
            localSnapshot.yawDegrees = motion.yawDegrees

            // 2. Velocity → position, resolved against the world.
            //    Deterministic and shared with the host — see WorldCollider.
            let collision = WorldCollider.resolve(
                position: localSnapshot.position,
                velocity: localSnapshot.velocity,
                body: .default,
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
            publishIfDue()
        }

        /// Third-person orbit camera, pulled in when a wall is in the way.
        private func updateCamera(dt: Float) {
            let pitch = max(-75, min(20, parent.cameraPitch))
            let orbit = Quat.euler(degrees: Vec3(pitch, parent.cameraYaw, 0))

            let focus = localSnapshot.position + Vec3(0, 1.4, 0)
            let desiredDistance: Float = 6.5
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
