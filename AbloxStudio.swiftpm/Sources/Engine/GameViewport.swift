import SwiftUI
import RealityKit
import ARKit
import simd
import Combine

/// Lets the play screen reach into the viewport for the things that are
/// actions rather than state: a screenshot, back to the start.
@MainActor
public final class ViewportLink {
    weak var coordinator: GameViewport.Coordinator?

    public init() {}

    /// The 3D view as a picture (no buttons, no chat), or nil.
    public func snapshot(_ completion: @escaping (UIImage?) -> Void) {
        guard let coordinator else { return completion(nil) }
        coordinator.snapshot(completion)
    }

    /// Back to the world's spawn point.
    public func returnToStart() {
        coordinator?.returnToStart()
    }
}

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
    /// Settings → Graphics. `auto` steps down by itself below 30 fps.
    var graphicsQuality: GraphicsQuality
    /// A small frame-rate counter at the top of the screen.
    var showFrameRate: Bool
    /// Settings → Comfort and the play screen's extras: shake, field of
    /// view, zoom, vibration, battery and heat, auto-jump.
    var preferences: PlayPreferences
    /// Watching someone else: the camera follows them instead.
    var spectating: PeerID?
    /// The player's own choice of first person where the game leaves the
    /// camera to them.
    var preferFirstPerson: Bool
    /// Photo mode: no names or bubbles, and the camera may go further out.
    var photoMode: Bool
    var link: ViewportLink?

    public init(
        session: SessionCoordinator,
        input: Binding<MovementInput>,
        cameraYaw: Binding<Float>,
        cameraPitch: Binding<Float>,
        soundEnabled: Bool = true,
        hapticsEnabled: Bool = true,
        isFiring: Bool = false,
        graphicsQuality: GraphicsQuality = .auto,
        showFrameRate: Bool = false,
        preferences: PlayPreferences = PlayPreferences(),
        spectating: PeerID? = nil,
        preferFirstPerson: Bool = false,
        photoMode: Bool = false,
        link: ViewportLink? = nil,
        onBlockTapped: ((UUID) -> Void)? = nil
    ) {
        self.session = session
        self._input = input
        self._cameraYaw = cameraYaw
        self._cameraPitch = cameraPitch
        self.soundEnabled = soundEnabled
        self.hapticsEnabled = hapticsEnabled
        self.isFiring = isFiring
        self.graphicsQuality = graphicsQuality
        self.showFrameRate = showFrameRate
        self.preferences = preferences
        self.spectating = spectating
        self.preferFirstPerson = preferFirstPerson
        self.photoMode = photoMode
        self.link = link
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
        link?.coordinator = context.coordinator
        context.coordinator.setFeedbackEnabled(sound: soundEnabled && preferences.effectsVolume > 0.02, haptics: hapticsEnabled)
        context.coordinator.setPreferences(preferences)
        context.coordinator.setGraphics(quality: graphicsQuality, showFrameRate: showFrameRate)
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

        /// No RealityKit colliders: movement, shots and taps all use the
        /// world index, and a collider per part was work nothing read.
        private let worldScene = WorldScene(collisionShapes: false)
        /// Block bounds and a grid over them, rebuilt only when blocks change.
        private let indexCache = WorldIndexCache()

        // MARK: Graphics

        private var graphicsQuality: GraphicsQuality = .auto
        private var governor = FrameRateGovernor()
        private var appliedProfile: GraphicsProfile?
        private var cullClock: Float = 0
        private var fpsLabel: UILabel?
        private var fpsClock: Float = 0
        /// Whether each avatar should be shown, before distance is considered.
        private var avatarHidden: [PeerID: Bool] = [:]
        private let cameraAnchor = AnchorEntity(world: .zero)
        private let camera = PerspectiveCamera()

        private var avatars: [PeerID: AvatarEntity] = [:]
        private var localAvatar: AvatarEntity?
        /// Speech bubbles over heads, drawn over the 3D view.
        private var chatBubbles: ChatBubbleOverlay?
        /// Names and titles over heads, and emoji stamps.
        private var nameTags: NameTagOverlay?

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
        private var lastWorldID: UUID?

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

        /// Settings → Comfort and friends.
        private var preferences = PlayPreferences()
        /// The best graphics level the battery and the iPad's heat allow.
        private var powerCap: GraphicsProfile.Level?
        private var powerClock: Float = 5

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

            let tags = NameTagOverlay(frame: view.bounds)
            tags.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(tags)
            nameTags = tags

            let bubbles = ChatBubbleOverlay(frame: view.bounds)
            bubbles.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(bubbles)
            chatBubbles = bubbles

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

        func setPreferences(_ preferences: PlayPreferences) {
            guard preferences != self.preferences else { return }
            let batteryChanged = preferences.batterySaver != self.preferences.batterySaver
                || preferences.coolDownWhenHot != self.preferences.coolDownWhenHot
            self.preferences = preferences
            switch preferences.hapticStrength {
            case .light: feedback.hapticIntensity = 0.45
            case .medium: feedback.hapticIntensity = 0.8
            case .strong: feedback.hapticIntensity = 1
            }
            if batteryChanged { powerClock = 5 }
        }

        func detach() {
            updateSubscription?.cancel()
            updateSubscription = nil
            worldScene.removeAll()
            avatars.removeAll()
            chatBubbles?.removeAll()
            chatBubbles?.removeFromSuperview()
            chatBubbles = nil
            nameTags?.removeAll()
            nameTags?.removeFromSuperview()
            nameTags = nil
        }

        // MARK: Screenshots and the start

        func snapshot(_ completion: @escaping (UIImage?) -> Void) {
            guard let view else { return completion(nil) }
            // The view's own layers only: no buttons, no chat, no names.
            view.snapshot(saveToHDR: false) { image in
                completion(image)
            }
        }

        func returnToStart() {
            let world = parent.session.world
            let index = parent.session.people.firstIndex { $0.peerID == parent.session.localPeerID } ?? 0
            respawn(in: world, index: index)
            publisher.reset()
        }

        // MARK: Sync

        func syncWorld(_ world: WorldDocument) {
            // `modifiedAt` is the cheap revision check; a full diff of every
            // block on every SwiftUI update would be wasteful, and WorldScene
            // does its own per-block diffing anyway.
            //
            // The world's id is checked too. Every catalogue game carries the
            // same `modifiedAt` — the day the catalogue was built — and the
            // viewport is made before the session switches to the new game,
            // so a date-only check kept drawing the previous game's map while
            // the player walked (and collided) in the new one.
            guard world.id != lastWorldID || world.modifiedAt != lastWorldRevision else { return }
            lastWorldID = world.id
            lastWorldRevision = world.modifiedAt
            // RealityKit physics only matters for parts that can fall. The
            // players' own movement never used it, and a static body per part
            // was simulated every frame for nothing.
            worldScene.sync(to: world, physicsEnabled: world.blocks.contains { !$0.isAnchored })

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
                    if avatarHidden[player.peerID] != player.isHidden {
                        avatarHidden[player.peerID] = player.isHidden
                        existing.isEnabled = !player.isHidden
                    }
                } else {
                    let avatar = AvatarEntity(peerID: player.peerID, profile: player.profile, position: player.position)
                    avatarHidden[player.peerID] = player.isHidden
                    avatar.isEnabled = !player.isHidden
                    worldScene.anchor.addChild(avatar)
                    avatars[player.peerID] = avatar
                }
            }

            for (peerID, avatar) in avatars where !seen.contains(peerID) {
                avatar.removeFromParent()
                avatars.removeValue(forKey: peerID)
                avatarHidden.removeValue(forKey: peerID)
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
                    case let .gesture(speaker, wire):
                        switch Gesture(wire: wire) {
                        case let .emote(emote)?:
                            let avatar = speaker == parent.session.localPeerID ? localAvatar : avatars[speaker]
                            avatar?.play(emote)
                        case let .stamp(emoji)?:
                            nameTags?.showStamp(emoji, for: speaker)
                        case nil:
                            break
                        }
                    case let .shake(strength, seconds):
                        shakeStrength = preferences.shake(strength: strength)
                        shakeRemaining = shakeStrength > 0 ? Float(seconds) : 0
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
            let index = indexCache.index(for: world)
            let dt = min(deltaTime, 1.0 / 20)
            elapsed += Double(dt)
            watchFrameRate(deltaTime)

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
            // Auto-jump: up a step too tall to walk, or over a gap with
            // somewhere to land.
            if preferences.autoJump, !scale.frozen, localSnapshot.isGrounded, shouldAutoJump(index: index) {
                input.isJumping = true
            }
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
                index: index,
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

            // 4. Drive the local avatar directly — no easing, it is ours —
            //    with the walk cycle, or the emote it is playing.
            if let local = localAvatar {
                let travelled = localSnapshot.position.horizontalDistance(to: Vec3(local.position))
                local.teleport(to: localSnapshot.position, yawDegrees: localSnapshot.yawDegrees)
                local.animate(travelled: travelled, deltaTime: dt)
            }

            // 5. Ease everyone else toward their last known transform.
            for avatar in avatars.values {
                avatar.update(deltaTime: dt)
            }

            // 6. Apply anything the host told us to do since the last frame.
            let effects = parent.session.drainEffects()
            if !effects.isEmpty { apply(effects: effects) }

            updateCamera(dt: dt, index: index)
            updateChatBubbles()
            updateNameTags()
            updateWeapons(dt: dt)
            if parent.isFiring { fireIfReady(index: index) }
            fadeTracers(dt: dt)
            publishIfDue()

            cullClock += dt
            if cullClock >= 0.25 {
                cullClock = 0
                cullFarAway(index: index)
            }
            powerClock += dt
            if powerClock >= 5 {
                powerClock = 0
                checkPowerAndHeat()
            }
        }

        /// Low Power Mode, the battery saver and a hot iPad all cap the
        /// graphics — checked every few seconds, since they change slowly.
        private func checkPowerAndHeat() {
            let heat: DeviceHeat
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: heat = .nominal
            case .fair: heat = .fair
            case .serious: heat = .serious
            case .critical: heat = .critical
            @unknown default: heat = .fair
            }
            let cap = preferences.graphicsCap(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, heat: heat)
            guard cap != powerCap else { return }
            powerCap = cap
            apply(profile: .profile(for: capped(appliedLevel)))
        }

        /// The level chosen by the setting or the governor, before any cap.
        private var appliedLevel: GraphicsProfile.Level {
            graphicsQuality.fixedLevel ?? governor.level
        }

        private func capped(_ level: GraphicsProfile.Level) -> GraphicsProfile.Level {
            guard let powerCap else { return level }
            return min(level, powerCap)
        }

        /// Whether the way ahead needs a jump: a solid edge between knee and
        /// head height just in front, or a gap with ground a jump away.
        private func shouldAutoJump(index: WorldIndex) -> Bool {
            let flat = Vec3(localSnapshot.velocity.x, 0, localSnapshot.velocity.z)
            guard flat.length > 1 else { return false }
            let direction = flat.normalized
            let size = parent.session.localAppearance.height
            let feet = localSnapshot.position
            func solid(_ box: BoundingBox) -> Bool {
                index.entries(near: box).contains { $0.hasCollision && $0.isVisible && $0.bounds.intersects(box) }
            }
            let near = feet + direction * (0.4 * size + 0.3)
            let step = BoundingBox(min: Vec3(near.x - 0.15, feet.y + 0.5, near.z - 0.15),
                                   max: Vec3(near.x + 0.15, feet.y + 1.1, near.z + 0.15))
            let headroom = BoundingBox(min: Vec3(near.x - 0.15, feet.y + 1.4, near.z - 0.15),
                                       max: Vec3(near.x + 0.15, feet.y + 2.4 * size, near.z + 0.15))
            if solid(step) && !solid(headroom) { return true }

            let ahead = feet + direction * (0.4 * size + 0.6)
            let floor = BoundingBox(min: Vec3(ahead.x - 0.2, feet.y - 3, ahead.z - 0.2), max: Vec3(ahead.x + 0.2, feet.y + 0.05, ahead.z + 0.2))
            guard !solid(floor) else { return false }
            let landing = feet + direction * 3
            let ground = BoundingBox(min: Vec3(landing.x - 0.4, feet.y - 1.5, landing.z - 0.4), max: Vec3(landing.x + 0.4, feet.y + 0.6, landing.z + 0.4))
            return solid(ground)
        }

        // MARK: Graphics

        func setGraphics(quality: GraphicsQuality, showFrameRate: Bool) {
            if quality != graphicsQuality || appliedProfile == nil {
                graphicsQuality = quality
                // Auto starts from the top and steps down if it has to.
                governor = FrameRateGovernor(startingAt: quality.fixedLevel ?? .high)
                apply(profile: .profile(for: capped(governor.level)))
            }
            setFrameRateLabel(visible: showFrameRate)
        }

        private func apply(profile: GraphicsProfile) {
            guard profile != appliedProfile else { return }
            appliedProfile = profile
            worldScene.setGraphics(profile)
            guard let view else { return }

            // Fewer pixels: the biggest single saving on an iPad's screen.
            let native = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
            if native > 0 {
                view.contentScaleFactor = native * CGFloat(profile.resolutionScale)
            }

            let effects: ARView.RenderOptions = [.disableHDR, .disableGroundingShadows, .disableDepthOfField]
            if profile.postEffects {
                view.renderOptions.subtract(effects)
            } else {
                view.renderOptions.formUnion(effects)
            }
            cullClock = 1
        }

        /// Feeds the frame time to the governor, which on Auto may pick
        /// another level, and keeps the counter up to date.
        private func watchFrameRate(_ frameTime: Float) {
            if let level = governor.record(frameTime: Double(frameTime)), graphicsQuality == .auto {
                apply(profile: .profile(for: capped(level)))
            }
            fpsClock += frameTime
            if fpsClock >= 0.5, let fpsLabel, !fpsLabel.isHidden {
                fpsClock = 0
                let fps = Int(governor.framesPerSecond.rounded())
                let level = appliedProfile?.level ?? governor.level
                var text = "\(fps) fps · \(level.displayName)"
                if graphicsQuality == .auto { text += " (" + GraphicsQuality.auto.displayName + ")" }
                fpsLabel.text = text
                fpsLabel.textColor = fps >= Int(FrameRateGovernor.minimumFPS) ? .white : UIColor(red: 1, green: 0.55, blue: 0.5, alpha: 1)
            }
        }

        private func setFrameRateLabel(visible: Bool) {
            guard let view else { return }
            if visible, fpsLabel == nil {
                let label = UILabel()
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                label.textColor = .white
                label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
                label.textAlignment = .center
                label.layer.cornerRadius = 6
                label.clipsToBounds = true
                label.text = "… fps"
                label.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
                    label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    label.widthAnchor.constraint(equalToConstant: 170),
                    label.heightAnchor.constraint(equalToConstant: 18)
                ])
                fpsLabel = label
            }
            fpsLabel?.isHidden = !visible
        }

        /// Hides parts and characters beyond the view distance.
        private func cullFarAway(index: WorldIndex) {
            let eye = Vec3(camera.position(relativeTo: nil))
            worldScene.cull(from: eye, index: index)

            let distance = appliedProfile?.viewDistance
            for (peer, avatar) in avatars {
                let hidden = avatarHidden[peer] ?? false
                var show = !hidden
                if show, let distance {
                    // A little further than parts: a person popping in is
                    // more noticeable than a crate.
                    show = avatar.targetPosition.distance(to: eye) <= distance * 1.25
                }
                if avatar.isEnabled != show { avatar.isEnabled = show }
            }
        }

        /// Where the camera is centred: the local player, or whoever they
        /// are watching.
        private var subjectPosition: Vec3 {
            if let watched = parent.spectating, let avatar = avatars[watched] {
                return Vec3(avatar.position(relativeTo: nil))
            }
            return localSnapshot.position
        }

        /// The camera the world's script asked for: behind the player (the
        /// default, pulled in when a wall is in the way), at their eyes,
        /// looking down from above, or fixed in the world.
        private func updateCamera(dt: Float, index: WorldIndex) {
            var settings = parent.session.scripted.camera
            // The player may choose first person where the game leaves the
            // camera behind them; watching someone is always from behind.
            if settings.mode == .thirdPerson, parent.preferFirstPerson, parent.spectating == nil {
                settings.mode = .firstPerson
            }
            if parent.spectating != nil { settings.mode = .thirdPerson }
            if parent.photoMode { settings.distance = max(settings.distance, 6) * 1.6 }
            let size = parent.session.localAppearance.height
            camera.camera.fieldOfViewInDegrees = preferences.fieldOfView(game: settings.fieldOfView)

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
                let height = settings.distance * preferences.cameraZoom
                let offset = Quat.yaw(degrees: parent.cameraYaw).act(Vec3(0, height, height * 0.3))
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

            let pitch = parent.photoMode ? max(-85, min(60, parent.cameraPitch)) : max(-75, min(20, parent.cameraPitch))
            let orbit = Quat.euler(degrees: Vec3(pitch, parent.cameraYaw, 0))

            let focus = subjectPosition + Vec3(0, 1.4 * size, 0) + jitter
            // Pinch-to-zoom (and Settings) scale the game's own distance.
            let desiredDistance: Float = settings.distance * preferences.cameraZoom
            let offset = orbit.act(Vec3(0, 0, 1)) * desiredDistance

            // Keep the camera out of geometry: if the line from the player to
            // the camera crosses a block, sit just in front of it.
            var distance = desiredDistance
            if !parent.photoMode {
            let ray = Ray(origin: focus, direction: offset)
            // Only the parts near the line from the player to the camera.
            let reach = BoundingBox(min: focus.componentMin(focus + offset), max: focus.componentMax(focus + offset)).expanded(by: 0.5)
            for entry in index.entries(near: reach) where entry.hasCollision && entry.isVisible {
                if let hit = ray.intersects(entry.bounds.expanded(by: 0.25)), hit < distance {
                    distance = max(1.5, hit)
                }
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

        // MARK: Name tags

        /// Everyone's name (and title) over their head, and their stamps.
        private func updateNameTags() {
            guard let view, let overlay = nameTags else { return }
            let session = parent.session
            let eye = Vec3(camera.position(relativeTo: nil))
            var people: [PeerID: PlayerSnapshot] = [:]
            for player in session.roster { people[player.peerID] = player }
            var tags: [NameTagOverlay.Tag] = []
            // Our own head too, for our stamps; our own name is not shown.
            var subjects: [(PeerID, AvatarEntity)] = avatars.map { ($0.key, $0.value) }
            if let local = localAvatar { subjects.append((session.localPeerID, local)) }
            for (peer, avatar) in subjects {
                guard avatar.isEnabled, avatar.parent != nil else { continue }
                let top = Vec3(avatar.position(relativeTo: nil)) + Vec3(0, 2.05 * avatar.scale.y, 0)
                let toTop = top - eye
                let distance = toTop.length
                guard distance > 0.5, distance < 70, toTop.dot(viewDirection) > 0.2 * distance,
                      let point = view.project(top.simd) else { continue }
                let player = people[peer]
                let isLocal = peer == session.localPeerID
                tags.append(NameTagOverlay.Tag(
                    id: peer,
                    name: isLocal ? "" : (player?.profile.displayName ?? avatar.profile.displayName),
                    title: isLocal ? "" : (player?.profile.title ?? ""),
                    anchor: point, distance: distance, isNPC: player?.isNPC ?? false
                ))
            }
            overlay.update(tags, showNames: !parent.photoMode)
        }

        // MARK: Chat bubbles

        /// Puts what each person said in the last few seconds over their
        /// head. Runs every frame so the bubbles stay glued to moving heads;
        /// the work is a walk back through the newest chat lines and one
        /// projection per speaker.
        private func updateChatBubbles() {
            guard let view, let overlay = chatBubbles else { return }
            let session = parent.session
            let now = Date()

            var lines: [PeerID: [ChatBubbleOverlay.Message]] = [:]
            for entry in session.chatLog.reversed() {
                let age = now.timeIntervalSince(entry.timestamp)
                // The log is in order, so everything before this is older.
                if age > ChatBubbleOverlay.lifetime { break }
                // The game's own lines have no head to sit over.
                guard entry.senderID != SessionCoordinator.gamePeerID,
                      session.muteList.allows(entry.senderID, localPeerID: session.localPeerID) else { continue }
                var list = lines[entry.senderID] ?? []
                guard list.count < ChatBubbleOverlay.linesPerSpeaker else { continue }
                list.insert(ChatBubbleOverlay.Message(id: entry.id, text: entry.text, age: age), at: 0)
                lines[entry.senderID] = list
            }
            guard !lines.isEmpty || overlay.isShowingAnything else { return }

            let eye = Vec3(camera.position(relativeTo: nil))
            var speakers: [ChatBubbleOverlay.Speaker] = []
            for (peer, messages) in lines {
                let avatar = peer == session.localPeerID ? localAvatar : avatars[peer]
                // Hidden, culled, or our own head in first person: no bubble.
                guard let avatar, avatar.isEnabled, avatar.parent != nil else { continue }
                let top = Vec3(avatar.position(relativeTo: nil)) + Vec3(0, 2.35 * avatar.scale.y, 0)
                let toTop = top - eye
                let distance = toTop.length
                // Behind the camera, a projection lands on the screen
                // mirrored; better not to draw it at all.
                guard distance > 0.5, distance < 70, toTop.dot(viewDirection) > 0.2 * distance,
                      let point = view.project(top.simd) else { continue }
                speakers.append(ChatBubbleOverlay.Speaker(id: peer, messages: messages, anchor: point, distance: distance))
            }
            overlay.update(speakers)
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
        private func fireIfReady(index: WorldIndex) {
            let scripted = parent.session.scripted
            guard scripted.canFire, let weapon = scripted.weapon else { return }
            let interval = 1 / max(weapon.fireRate, 0.2)
            guard elapsed - lastShotTime >= interval else { return }
            lastShotTime = elapsed
            recoil = 1

            let eyes = localSnapshot.position + Vec3(0, PlayerHitBody.eyeHeight * parent.session.localAppearance.height, 0)
            parent.session.send(input: .fire(origin: eyes, direction: aimDirection(from: eyes, range: weapon.range, index: index)))
        }

        /// The shot leaves the eyes but must land under the crosshair, which
        /// in third person sits on a ray from the camera several metres
        /// behind them. So: find what the crosshair is on, then aim at that.
        private func aimDirection(from eyes: Vec3, range: Float, index: WorldIndex) -> Vec3 {
            let origin = Vec3(camera.position(relativeTo: nil))
            let blocks = index.solidBlocks
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
            // Picked against the world document rather than RealityKit
            // colliders, which the game no longer builds: the nearest visible,
            // solid part under the finger that is being drawn.
            guard let through = view.ray(through: location) else { return }
            let ray = Ray(origin: Vec3(through.origin), direction: Vec3(through.direction))
            let index = indexCache.index(for: parent.session.world)
            let reach = appliedProfile?.viewDistance ?? 400
            var nearest: (id: UUID, distance: Float)?
            for entry in index.solidBlocks {
                guard let hit = ray.intersects(entry.bounds), hit <= reach, hit < (nearest?.distance ?? .greatestFiniteMagnitude) else { continue }
                nearest = (entry.id, hit)
            }
            guard let blockID = nearest?.id else { return }

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
