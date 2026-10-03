import SwiftUI
import RealityKit
import ARKit
import simd
import Combine
import AbloxCore

/// Lets the play screen reach into the viewport for the things that are
/// actions rather than state: a screenshot, back to the start.
@MainActor
public final class ViewportLink {
    weak var coordinator: GameViewport.Coordinator?

    // Nonisolated so a view can make one as a `@State` default.
    nonisolated public init() {}

    /// The 3D view as a picture (no buttons, no chat), or nil.
    public func snapshot(_ completion: @escaping (UIImage?) -> Void) {
        guard let coordinator else { return completion(nil) }
        coordinator.snapshot(completion)
    }

    /// Back to the world's spawn point.
    public func returnToStart() {
        coordinator?.returnToStart()
    }

    /// Told of every sound the game plays, for sound captions.
    public var onSound: ((SoundCue) -> Void)? {
        didSet { coordinator?.listenForSounds() }
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
    /// The stick, the buttons and the camera, read every frame. The camera
    /// is turned by the player and, now and then, by the game.
    let controls: PlayControls
    var onBlockTapped: ((UUID) -> Void)?
    /// Mirrors the Settings toggles, which had nothing to switch off until
    /// sound existed.
    var soundEnabled: Bool
    var hapticsEnabled: Bool
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
    /// Friends in the room: a star by their names, and the only names shown
    /// when the player asked for friends' names only.
    var friends: Set<PeerID>

    public init(
        session: SessionCoordinator,
        controls: PlayControls,
        soundEnabled: Bool = true,
        hapticsEnabled: Bool = true,
        graphicsQuality: GraphicsQuality = .auto,
        showFrameRate: Bool = false,
        preferences: PlayPreferences = PlayPreferences(),
        spectating: PeerID? = nil,
        preferFirstPerson: Bool = false,
        photoMode: Bool = false,
        link: ViewportLink? = nil,
        friends: Set<PeerID> = [],
        onBlockTapped: ((UUID) -> Void)? = nil
    ) {
        self.session = session
        self.controls = controls
        self.soundEnabled = soundEnabled
        self.hapticsEnabled = hapticsEnabled
        self.graphicsQuality = graphicsQuality
        self.showFrameRate = showFrameRate
        self.preferences = preferences
        self.spectating = spectating
        self.preferFirstPerson = preferFirstPerson
        self.photoMode = photoMode
        self.link = link
        self.friends = friends
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
        // Before any part is built: dangers and goals marked, or not, for
        // this whole game.
        BlockEntityFactory.marksMeaning = preferences.markMeaning

        context.coordinator.attach(to: view)
        context.coordinator.applyColourVision(preferences.colourVision)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    public func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.noteSwiftUIUpdate()
        link?.coordinator = context.coordinator
        context.coordinator.listenForSounds()
        context.coordinator.setFeedbackEnabled(sound: soundEnabled && preferences.effectsVolume > 0.02, haptics: hapticsEnabled)
        context.coordinator.setPreferences(preferences)
        context.coordinator.setGraphics(quality: graphicsQuality, showFrameRate: showFrameRate)
        context.coordinator.syncRoster(session.livePlayers, localPeerID: session.localPeerID)
        // The world's blocks and effects are taken in the render loop, not
        // here: SwiftUI is told about them only ten times a second, and
        // `drainEffects()` changes the session, which must not happen while
        // SwiftUI is mid-update.
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
        /// Words floating over blocks, under the name tags.
        private var blockLabels: BlockLabelOverlay?
        /// Seconds of play, for blocks that move by themselves.
        private var animationClock: Double = 0

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
        private var shakeSerial = 0
        private var shakeRemaining: Float = 0
        private var shakeStrength: Float = 0
        /// "Camera follows behind me": the yaw it last saw or set, and a
        /// pause after the player turns the camera themselves.
        private var followSeenYaw: Float?
        private var followPause: Float = 0

        /// Settings → Comfort and friends.
        private var preferences = PlayPreferences()

        // MARK: The world's parts

        /// The sky, the weather, the day and the screen look.
        private var atmosphere: Atmosphere?
        private var particles: ParticleField?
        private var waypointOverlay: WaypointOverlay?
        /// Blocks giving off particles near the camera, looked for twice a second.
        private var emitters: [(id: UUID, kind: ParticleKind, position: Vec3)] = []
        private var emitterClock: Float = 1
        /// Where each moving platform was last frame, to carry whoever stands on it.
        private var platformOffsets: [UUID: Vec3] = [:]
        private var standingOn: UUID?
        /// The world as drawn this frame: moving platforms where the clock puts them.
        private var placedWorld: WorldDocument?
        private var surroundings: Surroundings = .normal
        private var musicPlaying: (track: MusicTrack?, volume: Float)?
        /// The best graphics level the battery and the iPad's heat allow.
        private var powerCap: GraphicsProfile.Level?
        private var powerClock: Float = 5
        /// Whether RealityKit physics is needed: only for parts that can fall.
        private var physicsNeeded = false
        /// The moving platforms, and where each was built, for the world
        /// revision they were found in.
        private var placedFrom: UInt64?
        private var elevatorHomes: [(id: UUID, home: Vec3, gimmick: GimmickSettings)] = []
        /// Labelled blocks near enough to show, looked for four times a second.
        private var labelCandidates: [UUID] = []
        private var labelClock: Float = 1
        /// The share of the screen's pixels drawn, as last set.
        private var appliedScale: CGFloat?
        /// The launch check's frame-rate run prints how fast it draws.
        private let reportsFrameRate = UserDefaults.standard.bool(forKey: "AbloxPlayBenchmark")
        private var reportedFrames: Double = 0
        private var reportedLevel: GraphicsProfile.Level?
        /// The run's three parts: merged meshes on High, every part on its
        /// own on High (to compare), then merged meshes on Auto.
        private var benchmarkPhase = 0
        private var benchmarkStart: Double?
        private static let benchmarkPhases = ["merged-high", "single-high", "merged-auto"]
        /// Time spent in `tick` over the last second, for the run's report.
        private var tickSeconds: Double = 0
        private var tickLongest: Double = 0
        private var tickCount = 0
        /// How long the main thread was awake over the last second, and how
        /// often SwiftUI asked the view to update.
        private var mainThreadWatch: CFRunLoopObserver?
        private var mainAwakeSince: Double?
        private var mainAwake: Double = 0
        private var swiftUIUpdates = 0

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

            let words = BlockLabelOverlay(frame: view.bounds)
            words.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(words)
            blockLabels = words

            let tags = NameTagOverlay(frame: view.bounds)
            tags.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(tags)
            nameTags = tags

            let bubbles = ChatBubbleOverlay(frame: view.bounds)
            bubbles.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(bubbles)
            chatBubbles = bubbles

            let sky = Atmosphere(parent: worldScene.anchor)
            sky.attach(to: view)
            sky.setColourVision(preferences.colourVision)
            atmosphere = sky
            particles = ParticleField(parent: worldScene.anchor)
            let waypoint = WaypointOverlay(frame: view.bounds)
            waypoint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(waypoint)
            waypointOverlay = waypoint

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
            SoundSynth.shared.musicGain = parent.soundEnabled ? Float(preferences.musicVolume) : 0
        }

        func setPreferences(_ preferences: PlayPreferences) {
            guard preferences != self.preferences else { return }
            let batteryChanged = preferences.batterySaver != self.preferences.batterySaver
                || preferences.coolDownWhenHot != self.preferences.coolDownWhenHot
            self.preferences = preferences
            feedback.effectsVolume = Float(preferences.effectsVolume)
            SoundSynth.shared.musicGain = parent.soundEnabled ? Float(preferences.musicVolume) : 0
            if !preferences.readLinesAloud { LineReader.shared.stop() }
            switch preferences.hapticStrength {
            case .light: feedback.hapticIntensity = 0.45
            case .medium: feedback.hapticIntensity = 0.8
            case .strong: feedback.hapticIntensity = 1
            }
            if batteryChanged { powerClock = 5 }
            applyColourVision(preferences.colourVision)
        }

        func applyColourVision(_ vision: ColourVision) {
            atmosphere?.setColourVision(vision)
        }

        func detach() {
            updateSubscription?.cancel()
            updateSubscription = nil
            if let mainThreadWatch { CFRunLoopRemoveObserver(CFRunLoopGetMain(), mainThreadWatch, .commonModes) }
            mainThreadWatch = nil
            worldScene.removeAll()
            avatars.removeAll()
            chatBubbles?.removeAll()
            chatBubbles?.removeFromSuperview()
            chatBubbles = nil
            nameTags?.removeAll()
            nameTags?.removeFromSuperview()
            nameTags = nil
            blockLabels?.removeAll()
            blockLabels?.removeFromSuperview()
            blockLabels = nil
            particles?.removeAll()
            particles = nil
            atmosphere?.detach()
            atmosphere = nil
            waypointOverlay?.removeFromSuperview()
            waypointOverlay = nil
            SoundSynth.shared.setMusic(nil)
            LineReader.shared.stop()
        }

        // MARK: Screenshots and the start

        func snapshot(_ completion: @escaping (UIImage?) -> Void) {
            guard let view else { return completion(nil) }
            // The view's own layers only: no buttons, no chat, no names.
            view.snapshot(saveToHDR: false) { image in
                completion(image)
            }
        }

        /// Sound captions: every cue played goes to the link.
        func listenForSounds() {
            let link = parent.link
            feedback.onPlayed = link?.onSound == nil ? nil : { [weak link] cue in link?.onSound?(cue) }
        }

        func returnToStart() {
            let world = parent.session.world
            let index = parent.session.people.firstIndex { $0.peerID == parent.session.localPeerID } ?? 0
            respawn(in: world, index: index)
            publisher.reset()
        }

        // MARK: Sync

        /// Brings the 3D world up to date with the blocks that changed since
        /// the last frame: only those, unless something only a full look
        /// catches happened (`WorldChangeLog`).
        private func syncWorldChanges(_ world: WorldDocument, index: WorldIndex) {
            let changes = parent.session.takeWorldChanges()
            // The world's id, not only its blocks: the viewport is made before
            // the session switches to the new game, and every catalogue game
            // carries the same dates, so a new game must be drawn from scratch.
            if world.id != lastWorldID {
                lastWorldID = world.id
                worldScene.removeAll()
                physicsNeeded = world.blocks.contains { !$0.isAnchored }
                worldScene.sync(to: world, physicsEnabled: physicsNeeded)
                platformOffsets.removeAll()
                emitterClock = 1
                labelClock = 1
                return
            }
            guard !changes.isEmpty else { return }
            // RealityKit physics only matters for parts that can fall. The
            // players' own movement never used it, and a static body per part
            // was simulated every frame for nothing.
            if changes.everything {
                physicsNeeded = world.blocks.contains { !$0.isAnchored }
                platformOffsets.removeAll()
                emitterClock = 1
            } else if !physicsNeeded {
                physicsNeeded = changes.blocks.contains { id in
                    guard let entry = index.entry(for: id), entry.order < world.blocks.count else { return false }
                    return !world.blocks[entry.order].isAnchored
                }
            }
            worldScene.sync(to: world, changes: changes, index: index, physicsEnabled: physicsNeeded)
        }

        /// Where everyone else is this frame. Their looks, arrivals and
        /// leavings are seen to ten times a second (`syncRoster`).
        private func followPlayers() {
            let session = parent.session
            let local = session.localPeerID
            for player in session.livePlayers where player.peerID != local {
                guard let avatar = avatars[player.peerID] else { continue }
                avatar.targetPosition = player.position
                avatar.targetYawDegrees = player.yawDegrees
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
                case let .script(.sound(request)):
                    feedback.play(request)
                case let .script(.particles(burst)):
                    particles?.burst(burst)
                case let .script(.speak(text)):
                    if preferences.readLinesAloud, parent.soundEnabled {
                        LineReader.shared.speak(text, volume: Float(preferences.effectsVolume))
                    }
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
                        parent.controls.cameraYaw = -yaw
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

        /// Sparkles, bubbles… behind anyone wearing a trail, while they move.
        private func emitTrails(dt: Float) {
            guard let particles else { return }
            var subjects: [(PeerID, AvatarEntity)] = avatars.map { ($0.key, $0.value) }
            if let local = localAvatar { subjects.append((parent.session.localPeerID, local)) }
            let time = Date().timeIntervalSinceReferenceDate
            for (peer, avatar) in subjects where avatar.lastStep > 0.01 {
                let trail = avatar.profile.trail
                guard let kind = trail.particles else { continue }
                let at = Vec3(avatar.position) + Vec3(0, 0.25, 0)
                particles.stream(kind, key: "trail.\(peer)", at: at, rate: 14, spread: Vec3(0.15, 0.08, 0.15), dt: dt,
                                 color: trail.color(at: time))
            }
        }

        private func tick(deltaTime: Float) {
            let started = reportsFrameRate ? CACurrentMediaTime() : 0
            defer { if reportsFrameRate { noteTickTime(CACurrentMediaTime() - started) } }
            if reportsFrameRate { runBenchmarkPhases() }
            let dt = min(deltaTime, 1.0 / 20)
            // Everything the game changed since the last frame, in one go.
            let session = parent.session
            session.receiveWorldChanges()
            session.receiveTransforms()
            let world = placeMovingParts(in: session.world)
            let index = indexCache.index(for: world)
            syncWorldChanges(session.world, index: index)
            followPlayers()
            worldScene.update()
            elapsed += Double(dt)
            watchFrameRate(deltaTime)

            // 1. Intent → velocity, scaled by whatever the script allows.
            let scripted = parent.session.scripted
            let scale = scripted.movement
            let controls = parent.controls
            var input = controls.movementInput
            if scale.frozen {
                input.stick = .zero
                input.isJumping = false
            }
            var movement = MovementConfig.default
            movement.walkSpeed *= scale.speed
            // Access options: a gentler pace for anyone who needs it.
            movement.walkSpeed *= Float(preferences.access.movementSpeed)
            movement.jumpSpeed *= scale.jump
            // The world's gravity (Earth's by default) times the player's own.
            let worldGravity = world.environment.gravity / -9.81
            movement.gravity *= scale.gravity * (worldGravity.isFinite ? max(0, min(5, worldGravity)) : 1)
            // Auto-jump: up a step too tall to walk, or over a gap with
            // somewhere to land.
            if preferences.autoJump, !scale.frozen, localSnapshot.isGrounded, shouldAutoJump(index: index) {
                input.isJumping = true
            }
            // Swimming and climbing are worked out here, from the world.
            let size = parent.session.localAppearance.height
            let body = CharacterBody(radius: 0.4 * size, height: 1.8 * size)
            let around = Surroundings.find(at: localSnapshot.position, body: body, in: index)
            if case .water = around, surroundings == .normal || surroundings == .ladder {
                if localSnapshot.velocity.y < -4 { feedback.play(.splash, volume: 0.6) }
            }
            surroundings = around
            let motion = CharacterSolver.step(snapshot: localSnapshot, input: input, config: movement, surroundings: around,
                                              floats: parent.session.localAppearance.ride == .hoverboard, deltaTime: dt)
            localSnapshot.velocity = motion.velocity
            localSnapshot.yawDegrees = motion.yawDegrees
            if scripted.camera.mode == .firstPerson || scripted.weapon != nil {
                // Aiming: the body faces where the camera looks, so walking
                // sideways strafes instead of turning away from the target.
                let forward = Quat.yaw(degrees: controls.cameraYaw).act(Vec3(0, 0, -1))
                localSnapshot.yawDegrees = atan2(forward.x, -forward.z) * 180 / .pi
            } else {
                followCamera(stick: input.stick, dt: dt)
            }

            // 2. Velocity → position, resolved against the world.
            //    Deterministic and shared with the host — see WorldCollider.
            let collision = WorldCollider.resolve(
                position: localSnapshot.position,
                velocity: localSnapshot.velocity,
                body: body,
                index: index,
                deltaTime: dt
            )
            localSnapshot.position = collision.position
            localSnapshot.velocity = collision.velocity
            localSnapshot.isGrounded = collision.isGrounded
            standingOn = collision.isGrounded ? platform(under: localSnapshot.position, index: index) : nil

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
            emitTrails(dt: dt)

            // 6. Apply anything the host told us to do since the last frame.
            let effects = parent.session.drainEffects()
            if !effects.isEmpty { apply(effects: effects) }

            updateCamera(dt: dt, index: index)
            // The compass and a turning map catch up a few times a second.
            controls.showBearing(at: CACurrentMediaTime())
            updateAtmosphere(world: world, index: index, dt: dt)
            updateWaypoint()
            updateMusic(world: world)
            updateChatBubbles()
            updateNameTags()
            updateBlockLabels()
            animationClock += Double(dt)
            worldScene.animateBlocks(time: animationClock, eye: Vec3(camera.position(relativeTo: nil)))
            labelClock += dt
            updateWeapons(dt: dt)
            if controls.wantsToFire { fireIfReady(index: index) }
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

        /// Play screen options: the camera drifts round behind a player who
        /// walks on, but leaves it be for a moment after they turn it
        /// themselves.
        private func followCamera(stick: Vec3, dt: Float) {
            let yaw = parent.controls.cameraYaw
            var seen = yaw
            defer { followSeenYaw = seen }
            guard preferences.hud.cameraFollows, !parent.photoMode, parent.spectating == nil, !parent.preferFirstPerson,
                  parent.session.scripted.camera.mode == .thirdPerson else { return }
            if let last = followSeenYaw, abs(normalizeDegrees(yaw - last)) > 0.01 {
                followPause = 1.5
            }
            if followPause > 0 {
                followPause -= dt
                return
            }
            let turn = CameraHabits.followTurn(cameraYaw: yaw, bodyYaw: localSnapshot.yawDegrees, stick: stick, seconds: dt)
            guard turn != 0 else { return }
            seen = normalizeDegrees(yaw + turn)
            parent.controls.cameraYaw = seen
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
            // Auto starts its steps down from the cap, not from above it.
            if let cap, graphicsQuality == .auto { governor.limit(to: cap) }
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

        /// Counted for the frame-rate run.
        func noteSwiftUIUpdate() {
            if reportsFrameRate { swiftUIUpdates += 1 }
        }

        /// Measures how long the main thread is awake: between waking and
        /// going back to sleep, it runs this view, SwiftUI and UIKit.
        private func watchMainThread() {
            guard reportsFrameRate, mainThreadWatch == nil else { return }
            let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    if activity == .afterWaiting {
                        self.mainAwakeSince = now
                    } else if let since = self.mainAwakeSince {
                        self.mainAwake += now - since
                        self.mainAwakeSince = nil
                    }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            mainThreadWatch = observer
        }

        func setGraphics(quality: GraphicsQuality, showFrameRate: Bool) {
            // The frame-rate run sets its own level for each of its parts.
            let quality = reportsFrameRate ? (benchmarkPhase == 2 ? GraphicsQuality.auto : .high) : quality
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
            switch profile.level {
            case .high: particles?.budget = 600
            case .medium: particles?.budget = 300
            case .low: particles?.budget = 140
            case .lightest: particles?.budget = 60
            }
            guard let view else { return }

            applyResolution()

            let effects: ARView.RenderOptions = [.disableHDR, .disableGroundingShadows, .disableDepthOfField]
            if profile.postEffects {
                view.renderOptions.subtract(effects)
            } else {
                view.renderOptions.formUnion(effects)
            }
            cullClock = 1
        }

        /// Fewer pixels: the biggest single saving on an iPad's screen. The
        /// level's share, and on Auto a little less while the game is not
        /// quite smooth (`FrameRateGovernor.resolutionFactor`).
        private func applyResolution() {
            guard let view, let profile = appliedProfile else { return }
            let native = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
            guard native > 0 else { return }
            let factor = graphicsQuality == .auto ? governor.resolutionFactor : 1
            let scale = native * CGFloat(profile.resolutionScale * factor)
            guard scale != appliedScale else { return }
            appliedScale = scale
            view.contentScaleFactor = scale
        }

        /// Feeds the frame time to the governor, which on Auto may pick
        /// another level or draw a few pixels fewer, and keeps the counter
        /// up to date.
        private func watchFrameRate(_ frameTime: Float) {
            let windows = governor.framesPerSecond
            if let level = governor.record(frameTime: Double(frameTime)), graphicsQuality == .auto {
                apply(profile: .profile(for: capped(level)))
            }
            if governor.framesPerSecond != windows {
                // A window of frames has been counted.
                applyResolution()
                if reportsFrameRate { reportFrameRate() }
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

        /// The frame-rate run: 40 seconds of merged meshes on High (sampled
        /// from the outside at 26 to 34), 20 with every part drawn on its
        /// own, then merged meshes on Auto.
        private func runBenchmarkPhases() {
            watchMainThread()
            let now = CACurrentMediaTime()
            let start = benchmarkStart ?? now
            benchmarkStart = start
            // Looking round the town, as a player does.
            parent.controls.cameraYaw = normalizeDegrees(Float(now - start) * 24)
            let phase = now - start < 40 ? 0 : (now - start < 60 ? 1 : 2)
            guard phase != benchmarkPhase else { return }
            benchmarkPhase = phase
            worldScene.bakesStillParts = phase != 1
            setGraphics(quality: parent.graphicsQuality, showFrameRate: parent.showFrameRate)
        }

        private func noteTickTime(_ seconds: Double) {
            tickSeconds += seconds
            tickLongest = max(tickLongest, seconds)
            tickCount += 1
        }

        /// One line a second for the launch check (stderr, which is not held
        /// back in a buffer): frames per second, the run's part, level,
        /// pixels, time in `tick` (mean and longest), merged meshes, the
        /// parts in them and the parts drawn on their own.
        private func reportFrameRate() {
            reportedFrames += 1
            let merged = worldScene.mergedSummary
            let level = appliedProfile?.level ?? governor.level
            let mean = tickCount > 0 ? tickSeconds / Double(tickCount) * 1000 : 0
            let line = String(format: "AbloxFPS %.1f phase=%@ level=%@ pixels=%.2f cpu=%.1f/%.1fms main=%.0f%% ui=%ld meshes=%ld baked=%ld single=%ld second=%.0f\n",
                              governor.framesPerSecond, Self.benchmarkPhases[benchmarkPhase], level.displayName,
                              Double(governor.resolutionFactor), mean, tickLongest * 1000, min(100, mainAwake * 100),
                              swiftUIUpdates, merged.meshes, merged.parts, worldScene.partsDrawnOnTheirOwn, reportedFrames)
            tickSeconds = 0
            tickLongest = 0
            tickCount = 0
            mainAwake = 0
            swiftUIUpdates = 0
            FileHandle.standardError.write(Data(line.utf8))
            if let profile = appliedProfile, profile.level != reportedLevel {
                reportedLevel = profile.level
                FileHandle.standardError.write(Data("AbloxShapes \(profile.level.displayName): \(UnitShapes.describe(profile))\n".utf8))
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
                let pitch = max(-80, min(80, parent.controls.cameraPitch))
                let look = Quat.euler(degrees: Vec3(pitch, parent.controls.cameraYaw, 0)).act(Vec3(0, 0, -1))
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
                let offset = Quat.yaw(degrees: parent.controls.cameraYaw).act(Vec3(0, height, height * 0.3))
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

            let held = parent.controls
            let pitch = parent.photoMode ? max(-85, min(60, held.cameraPitch)) : max(-75, min(20, held.cameraPitch))
            let orbit = Quat.euler(degrees: Vec3(pitch, held.cameraYaw, 0))

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

        // MARK: Moving platforms

        /// The world with its moving platforms where the clock puts them —
        /// drawn there, walked on there — and whoever stands on one carried
        /// along with it. Every iPad counts on its own clock (they agree to
        /// a few hundredths of a second), so nothing is sent while they move.
        private func placeMovingParts(in world: WorldDocument) -> WorldDocument {
            // Looked for again only when the blocks change: every block was
            // checked, and the whole world copied, every frame.
            if world.blockRevision.value != placedFrom {
                let previous = placedFrom
                placedFrom = world.blockRevision.value
                elevatorHomes = world.blocks.compactMap { block in
                    block.behavior == .elevator ? (id: block.id, home: block.position, gimmick: block.gimmick) : nil
                }
                if elevatorHomes.isEmpty {
                    placedWorld = nil
                } else {
                    // Only what changed, so the index looks at those alone
                    // rather than at every block of a copy made afresh.
                    var caughtUp = false
                    if var placed = placedWorld, let previous, let changed = world.blocksChanged(since: previous) {
                        // Let go of the stored copy first, so this one is
                        // changed in place rather than copied.
                        placedWorld = nil
                        caughtUp = Self.catchUp(&placed, with: world, at: changed)
                        if caughtUp { placedWorld = placed }
                    }
                    if !caughtUp { placedWorld = world }
                }
            }
            guard var placed = placedWorld else {
                platformOffsets.removeAll()
                return world
            }
            // Let go of the stored copy, so the one changed is the only one.
            placedWorld = nil
            let now = Date().timeIntervalSince1970
            var offsets: [UUID: Vec3] = [:]
            for platform in elevatorHomes {
                let offset = MovingParts.offset(for: platform.gimmick, at: now)
                let position = platform.home + offset
                // One block at a time, so the index looks at these alone.
                placed.mutate(id: platform.id) { $0.position = position }
                offsets[platform.id] = offset
                worldScene.place(platform.id, at: position)
            }
            if let standingOn, let before = platformOffsets[standingOn], let after = offsets[standingOn] {
                let carried = after - before
                if carried.lengthSquared > 0, carried.lengthSquared < 4 {
                    localSnapshot.position += carried
                }
            }
            platformOffsets = offsets
            placedWorld = placed
            return placed
        }

        /// Brings a copy up to date with the blocks of `world` at `orders`,
        /// one at a time. False when the two do not line up.
        private static func catchUp(_ copy: inout WorldDocument, with world: WorldDocument, at orders: [Int]) -> Bool {
            let blocks = world.blocks
            for order in orders {
                guard order < blocks.count else { return false }
                if order < copy.blocks.count {
                    guard copy.blocks[order].id == blocks[order].id else { return false }
                    copy.update(blocks[order])
                } else {
                    guard order == copy.blocks.count else { return false }
                    copy.insert(blocks[order])
                }
            }
            return copy.blocks.count == blocks.count
        }

        /// The moving platform under the feet, if any.
        private func platform(under feet: Vec3, index: WorldIndex) -> UUID? {
            guard !platformOffsets.isEmpty else { return nil }
            let probe = BoundingBox(min: feet - Vec3(0.3, 0.2, 0.3), max: feet + Vec3(0.3, 0.05, 0.3))
            return index.entries(near: probe).first { $0.behavior == .elevator && $0.bounds.intersects(probe) }?.id
        }

        // MARK: Sky, weather, particles, music

        private func updateAtmosphere(world: WorldDocument, index: WorldIndex, dt: Float) {
            let eye = Vec3(camera.position(relativeTo: nil))
            let environment = world.environment
            if let atmosphere {
                let light = atmosphere.update(environment: environment, camera: eye, dt: dt,
                                              reduceFlashing: preferences.reduceFlashing) { [weak self] in
                    guard let self, self.parent.soundEnabled else { return }
                    // Thunder comes a moment after the flash.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        self?.feedback.play(.explosion, volume: 0.35, pitch: 0.5)
                    }
                }
                worldScene.setDaylight(pitch: light.pitch, yaw: light.yaw, brightness: light.brightness)
            }

            guard let particles else { return }
            let share = Float(particles.budget) / 600
            if let falling = environment.weather.falling {
                let above: Float = falling == .rain ? 12 : 5
                particles.stream(falling, key: "weather", at: eye + Vec3(0, above, 0),
                                 rate: falling.spec.rate * share, spread: Vec3(16, 2, 16), dt: dt)
            }

            emitterClock += dt
            if emitterClock >= 0.5 {
                emitterClock = 0
                var found: [(id: UUID, kind: ParticleKind, position: Vec3, distance: Float)] = []
                for block in world.blocks where block.isVisible {
                    guard let kind = block.particles, let bounds = index.bounds(of: block.id) else { continue }
                    let rises = kind == .fire || kind == .smoke || kind == .bubbles
                    let position = rises ? Vec3(bounds.center.x, bounds.max.y, bounds.center.z) : bounds.center
                    let distance = position.distance(to: eye)
                    if distance < 45 { found.append((block.id, kind, position, distance)) }
                }
                emitters = found.sorted { $0.distance < $1.distance }.prefix(16).map { (id: $0.id, kind: $0.kind, position: $0.position) }
            }
            for emitter in emitters {
                particles.stream(emitter.kind, key: emitter.id.uuidString, at: emitter.position,
                                 rate: emitter.kind.spec.rate * 0.5 * share, spread: Vec3(0.2, 0, 0.2), dt: dt)
            }
            particles.update(dt: dt)
        }

        /// The script's music, or the world's, as loud as Settings says.
        private func updateMusic(world: WorldDocument) {
            let wanted: MusicTrack?
            let volume: Float
            if let play = parent.session.scripted.music {
                wanted = MusicTrack(rawValue: play.track)
                volume = play.volume
            } else {
                wanted = world.environment.music
                volume = 1
            }
            let track = parent.soundEnabled && preferences.musicVolume > 0.01 ? wanted : nil
            if let playing = musicPlaying, playing.track == track, playing.volume == volume { return }
            musicPlaying = (track, volume)
            SoundSynth.shared.setMusic(track, volume: volume)
        }

        /// The script's arrow: a pin on the place, or an arrow round the edge.
        private func updateWaypoint() {
            guard let view, let overlay = waypointOverlay else { return }
            guard let waypoint = parent.session.scripted.waypoint, !parent.photoMode else {
                overlay.hide()
                return
            }
            let target = waypoint.position + Vec3(0, 1, 0)
            let eye = Vec3(camera.position(relativeTo: nil))
            let toTarget = target - eye
            let distance = localSnapshot.position.distance(to: waypoint.position)
            let bounds = view.bounds.insetBy(dx: 40, dy: 60)
            if toTarget.dot(viewDirection) > 0.15 * toTarget.length, let point = view.project(target.simd), bounds.contains(point) {
                overlay.show(waypoint, distance: distance, onScreen: point, angle: 0)
                return
            }
            // Which way round the screen: right is along the camera's right,
            // up along its up.
            let right = viewDirection.cross(Vec3(0, 1, 0)).normalized
            let up = right.cross(viewDirection).normalized
            let angle = atan2(CGFloat(toTarget.dot(right)), CGFloat(toTarget.dot(up) + (toTarget.dot(viewDirection) < 0 ? -0.001 : 0)))
            overlay.show(waypoint, distance: distance, onScreen: nil, angle: angle)
        }

        // MARK: Name tags

        /// Everyone's name (and title) over their head, and their stamps.
        private func updateNameTags() {
            guard let view, let overlay = nameTags else { return }
            let session = parent.session
            let chat = preferences.chat
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
                let isFriend = parent.friends.contains(peer)
                // Chat options: whose names show, and a star by a friend's.
                let shown = !isLocal && chat.showsName(isFriend: isFriend)
                let name = player?.profile.displayName ?? avatar.profile.displayName
                tags.append(NameTagOverlay.Tag(
                    id: peer,
                    name: shown ? (isFriend && chat.markFriends ? "★ " + name : name) : "",
                    title: shown ? (player?.profile.title ?? "") : "",
                    anchor: point, distance: distance, isNPC: player?.isNPC ?? false,
                    plate: player?.profile.nameplate ?? avatar.profile.nameplate
                ))
            }
            overlay.sizeFactor = CGFloat(chat.nameSize.scale)
            overlay.update(tags, showNames: !parent.photoMode)
        }

        // MARK: Words over blocks

        /// Each labelled block's words just above it, if it is in front of
        /// the camera and within the label's range. Which labels are near
        /// enough is looked at four times a second, and only the nearest few
        /// dozen are followed every frame: a game with hundreds of labelled
        /// characters measured every one of them every frame.
        private func updateBlockLabels() {
            guard let view, let overlay = blockLabels else { return }
            let labelled = worldScene.labeledBlocks
            guard !labelled.isEmpty, !parent.photoMode else {
                if !labelCandidates.isEmpty { labelCandidates.removeAll() }
                overlay.update([])
                return
            }
            let eye = Vec3(camera.position(relativeTo: nil))
            let limit = appliedProfile?.labelLimit ?? 48
            overlay.maximumShown = limit
            if labelClock >= 0.25 {
                labelClock = 0
                var near: [(id: UUID, label: BlockLabel, distance: Float)] = []
                for (id, label) in labelled {
                    guard let entity = worldScene.entity(for: id), entity.isEnabled, entity.parent != nil else { continue }
                    let distance = Vec3(entity.position(relativeTo: nil)).distance(to: eye)
                    // A little further than the label reaches: it may come
                    // into range before the next look.
                    if distance < label.range + 8 { near.append((id, label, distance)) }
                }
                near.sort { $0.distance < $1.distance }
                labelCandidates = near.prefix(limit * 2).map { $0.id }
            }
            var items: [BlockLabelOverlay.Item] = []
            for id in labelCandidates {
                // The words as they are now: a price or a count changes often.
                guard let label = labelled[id], let entity = worldScene.entity(for: id), entity.isEnabled,
                      entity.parent != nil else { continue }
                let half = entity.scale(relativeTo: nil).y / 2
                let top = Vec3(entity.position(relativeTo: nil)) + Vec3(0, half + label.height, 0)
                let toTop = top - eye
                let distance = toTop.length
                guard distance > 0.5, distance < label.range, toTop.dot(viewDirection) > 0.2 * distance,
                      let point = view.project(top.simd) else { continue }
                items.append(BlockLabelOverlay.Item(id: id, label: label, anchor: point, distance: distance))
            }
            overlay.update(items)
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
            // Chat options: bubbles off, their size and how long they stay.
            let chat = preferences.chat
            overlay.sizeFactor = CGFloat(chat.bubbleSize.scale)

            var lines: [PeerID: [ChatBubbleOverlay.Message]] = [:]
            for entry in session.chatLog.reversed() where chat.showBubbles || entry.senderID == session.localPeerID {
                let seconds = now.timeIntervalSince(entry.timestamp)
                // The log is in order, so everything before this is older.
                if seconds > chat.bubbleTime.seconds { break }
                let age = chat.bubbleAge(seconds)
                // The game's own lines have no head to sit over.
                // Nor do whispers: they are not said out loud.
                guard entry.senderID != SessionCoordinator.gamePeerID, !entry.isPrivate,
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
                speakers.append(ChatBubbleOverlay.Speaker(id: peer, messages: messages, anchor: point, distance: distance,
                                                          style: avatar.profile.bubble))
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
            let index = indexCache.index(for: placedWorld ?? parent.session.world)
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
