import Foundation

/// Everything the host decides about a game in progress: the world's rules
/// (`EventMachine`) and the world's `.absc` scripts.
///
/// The two halves are one object because they share one world and one set of
/// players. A script that sets `p.score` has to trip the rule that ends the
/// round at 10 points; a rule that teleports a player has to move them where a
/// script's shot will look for them.
///
/// Like `EventMachine`, it has no clock and no networking: time and inputs are
/// passed in, and what comes out is effects (for players' screens), world
/// deltas (for everyone's copy of the map), NPC movement and a flag saying the
/// roster changed. That is what lets a whole match be played in a unit test.
///
/// The script API itself is in `GameRuntimeAPI.swift`.
public final class GameRuntime {

    public typealias Effect = EventMachine.Effect

    /// The handlers a script can write. Anything else after `on` is a typo,
    /// and `GameRuntime.check` says so.
    public enum Event: String, CaseIterable, Sendable {
        case start, tick, join, leave, touch, tap, fire, hit
        case hitBlock = "hit_block"
        case death, respawn, button, input, chat
        /// A player's saved data has arrived: `p.saved` is ready to read.
        case loaded
    }

    /// What `game.respawn_time = 5` and friends change.
    public struct Settings: Equatable, Sendable {
        /// Seconds between being knocked out and coming back. Negative means
        /// never on its own: the script calls `p.respawn()` when it wants.
        public var respawnTime: Double = 3
        /// Whether shots hurt teammates. Off, because in a team game written
        /// by a beginner, friendly fire is almost always a bug.
        public var friendlyFire = false

        public init() {}
    }

    /// Fuses, not rules. Each is far beyond what a game needs and only stops
    /// a runaway script from taking the host down with it.
    public enum Limits {
        public static let maximumTimers = 1_000
        public static let minimumRepeatInterval = 0.05
        public static let maximumCustomWeapons = 200
        /// How often `on touch` fires for the same character and block.
        /// Contact is reported on every physics step while standing on
        /// something.
        public static let touchInterval = 0.5
        public static let maximumHealth: Double = 1_000_000_000
        public static let maximumMovementMultiplier: Float = 10
        public static let maximumNPCs = 100
        public static let maximumBlocks = 20_000
        public static let maximumCustomValues = 1_000
        public static let maximumSize: Float = 10
        public static let minimumSize: Float = 0.2
    }

    // MARK: State

    public internal(set) var machine: EventMachine
    public internal(set) var settings = Settings()
    /// Syntax errors, one per broken file. The rules still run.
    public private(set) var compileErrors: [ScriptError] = []
    public private(set) var hasStarted = false

    public var world: WorldDocument { machine.world }

    /// Block bounds and a grid over them, rebuilt only when the blocks
    /// change — see `WorldIndex`. NPC movement and every shot use it.
    private let worldIndexCache = WorldIndexCache()
    var worldIndex: WorldIndex { worldIndexCache.index(for: world) }
    public var players: [PeerID: PlayerSnapshot] { machine.players }
    public var isRoundOver: Bool { machine.isRoundOver }
    public var isScriptRunning: Bool { interpreter != nil }
    public var compileError: ScriptError? { compileErrors.first }

    /// Everyone to draw: people from the rule machine, then NPCs, each with
    /// the script's hidden flag applied.
    public var roster: [PlayerSnapshot] {
        var list = machine.roster.map { snapshot -> PlayerSnapshot in
            var copy = snapshot
            copy.isHidden = states[snapshot.peerID]?.isHidden ?? false
            return copy
        }
        for state in orderedStates where state.isNPC {
            guard var body = state.body else { continue }
            body.isNPC = true
            body.isHidden = state.isHidden
            list.append(body)
        }
        return list
    }

    var interpreter: ScriptInterpreter?
    var fileNames: [String] = []
    var states: [PeerID: PlayerState] = [:]
    var joinCounter = 0
    var clock: Double
    var roundStartedAt: Double = 0
    var lastTick: Double?
    var lastNPCStep: Double?
    var timers: [ScriptTimer] = []
    var nextTimerID = 1
    var weapons: [String: WeaponSpec] = WeaponSpec.presets
    var globalUI: [String: UIElement] = [:]
    var globalUIOrder: [String] = []
    var lastTouch: [TouchKey: Double] = [:]
    var random: ScriptRandom
    let seed: UInt64
    let scriptLimits: ScriptInterpreter.Limits
    /// The world as it was before any script touched it, so a restarted
    /// round starts from the real map rather than the last round's rubble.
    let originalWorld: WorldDocument
    var pendingRestart = false
    /// Animated block moves whose end position has not yet been sent to
    /// everyone's copy of the world.
    var deferredUpdates: [(due: Double, blockID: UUID)] = []

    var pending: [Effect] = []
    var pendingDeltas: [WorldDelta] = []
    var npcTransforms: [PeerID: PlayerTransformPayload] = [:]
    var rosterChanged = false
    var newErrors: [ScriptError] = []
    var reportedErrors: Set<String> = []
    var output: [String] = []

    public init(world: WorldDocument, startTime: Double = 0, seed: UInt64 = 1,
                limits: ScriptInterpreter.Limits = ScriptInterpreter.Limits()) {
        self.machine = EventMachine(world: world, startTime: startTime)
        self.originalWorld = world
        self.clock = startTime
        self.seed = seed
        self.scriptLimits = limits
        self.random = ScriptRandom(seed: seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    // MARK: Roster

    /// Adds a player, or updates the profile of one already here.
    @discardableResult
    public func addPlayer(_ snapshot: PlayerSnapshot) -> [Effect] {
        collect {
            if let existing = states[snapshot.peerID] {
                machine.updateProfile(snapshot.profile, for: snapshot.peerID)
                existing.name = snapshot.profile.displayName
                existing.originalProfile = snapshot.profile
                return
            }
            machine.addPlayer(snapshot)
            let state = PlayerState(peer: snapshot.peerID, joinOrder: joinCounter,
                                    name: snapshot.profile.displayName, profile: snapshot.profile)
            joinCounter += 1
            states[snapshot.peerID] = state
            guard hasStarted, !isRoundOver else { return }
            welcome(state, replayingScreen: true)
        }
    }

    @discardableResult
    public func removePlayer(_ peer: PeerID) -> [Effect] {
        collect {
            if let state = states[peer], hasStarted, !isRoundOver {
                // Before removing them, so the handler can still read them.
                run(.leave, [object(for: state)])
            }
            machine.removePlayer(peer)
            states[peer] = nil
            lastTouch = lastTouch.filter { $0.key.peer != peer }
        }
    }

    public func updateTransform(_ payload: PlayerTransformPayload) {
        // NPCs are the host's own; nobody else may move them.
        guard states[payload.peerID]?.isNPC != true else { return }
        machine.updateTransform(payload)
    }

    // MARK: Observations and time

    @discardableResult
    public func handle(_ observation: EventMachine.Observation) -> [Effect] {
        collect {
            pending.append(contentsOf: machine.handle(observation))
            switch observation {
            case .roundStarted:
                beginRound()
            case let .touched(peer, blockID):
                touched(peer: peer, blockID: blockID)
            case let .tapped(peer, blockID):
                guard hasStarted, !isRoundOver, let state = states[peer], world.block(id: blockID) != nil else { return }
                run(.tap, [object(for: state), blockObject(blockID)])
            case .proximityEntered, .scoreChanged:
                break
            }
        }
    }

    @discardableResult
    public func advance(to time: Double) -> [Effect] {
        collect {
            clock = Swift.max(clock, time)
            if pendingRestart {
                pendingRestart = false
                pending.append(contentsOf: machine.handle(.roundStarted))
                beginRound()
                return
            }
            pending.append(contentsOf: machine.advance(to: time))
            flushDeferredUpdates()
            // Before the round-over check: what was saved as a round ended
            // still has to reach the iPad.
            flushSaves()
            guard hasStarted, !isRoundOver else { return }

            for state in orderedStates {
                if state.armed?.advance(to: clock) == true {
                    sendAmmo(state)
                }
                if !state.isAlive, let due = state.respawnAt, clock >= due {
                    respawn(state)
                }
            }

            stepNPCs()
            runDueTimers()
            guard !isRoundOver else { return }

            let delta = clock - (lastTick ?? clock)
            lastTick = clock
            run(.tick, [.number(delta)])
        }
    }

    /// A button press from a player. The host checks it; nothing a client
    /// sends here is believed as a result.
    @discardableResult
    public func handle(_ input: PlayerInputPayload.Input, from peer: PeerID, at time: Double) -> [Effect] {
        collect {
            clock = Swift.max(clock, time)
            // Saved data is kept even between rounds: arriving while a round
            // is over must not lose it for the rest of the session.
            if case let .saved(data) = input {
                if let state = states[peer], !state.isNPC { receiveSave(data, for: state) }
                return
            }
            guard hasStarted, !isRoundOver, let state = states[peer], !state.isNPC else { return }
            switch input {
            case let .fire(origin, direction):
                fire(state, origin: origin, direction: direction)
            case let .button(id):
                // Only a button that player can actually see. Otherwise any
                // client could press any button, including one the script
                // only shows to the winner.
                guard element(id, visibleTo: state)?.kind == .button else { return }
                run(.button, [object(for: state), .string(id)])
            case let .text(id, value):
                guard element(id, visibleTo: state)?.kind == .input else { return }
                run(.input, [object(for: state), .string(id), .string(String(value.prefix(UIElement.Limits.maximumTextLength)))])
            case .reload:
                guard state.isAlive, state.armed?.startReload(at: clock) == true else { return }
                sendAmmo(state)
                send(state, .playSound(name: SoundCue.reload.rawValue))
            case .saved:
                break
            }
        }
    }

    /// A chat message, for `on chat(p, text)` — commands, passwords, quizzes.
    @discardableResult
    public func handleChat(from peer: PeerID, text: String) -> [Effect] {
        collect {
            guard hasStarted, !isRoundOver, let state = states[peer] else { return }
            run(.chat, [object(for: state), .string(String(text.prefix(AbloxProtocol.maxChatLength)))])
        }
    }

    public func apply(_ delta: WorldDelta) {
        machine.apply(delta)
    }

    // MARK: What the host sends on

    /// Changes to the map since the last call, for everyone's copy.
    public func drainWorldDeltas() -> [WorldDelta] {
        defer { pendingDeltas.removeAll() }
        return pendingDeltas
    }

    /// Where the NPCs have moved since the last call.
    public func drainNPCTransforms() -> [PlayerTransformPayload] {
        defer { npcTransforms.removeAll() }
        return npcTransforms.values.sorted { $0.peerID.raw.uuidString < $1.peerID.raw.uuidString }
    }

    /// True once after anyone's name, look or visibility changed, or an NPC
    /// came or went: the host should send the roster again.
    public func takeRosterChange() -> Bool {
        defer { rosterChanged = false }
        return rosterChanged
    }

    // MARK: Diagnostics

    /// Errors not yet reported. Each distinct error is reported once: a
    /// mistake in `on tick` would otherwise repeat ten times a second.
    public func drainErrors() -> [ScriptError] {
        defer { newErrors.removeAll() }
        return newErrors
    }

    /// What `print` has written since the last call.
    public func drainOutput() -> [String] {
        if let interpreter { output.append(contentsOf: interpreter.drainOutput()) }
        defer { output.removeAll() }
        return output
    }

    /// Everything wrong with a set of `.absc` files that can be found without
    /// running them: syntax errors, and handlers for events that never
    /// happen. Studio's Check button.
    public static func check(_ files: [ScriptFile]) -> [ScriptError] {
        switch ScriptBundle.compile(files) {
        case let .failure(errors):
            return errors
        case let .success(bundle):
            return unknownEvents(in: bundle.program).map { $0.resolved(files: bundle.fileNames) }
        }
    }

    /// One source on its own, with plain line numbers.
    public static func check(_ source: String) -> [ScriptError] {
        do {
            return unknownEvents(in: try ScriptParser.parse(source))
        } catch let error as ScriptError {
            return [error]
        } catch {
            return [ScriptError(line: 1, kind: .syntax, message: String(describing: error))]
        }
    }

    private static func unknownEvents(in program: ScriptProgram) -> [ScriptError] {
        let known = Event.allCases.map(\.rawValue)
        var problems: [ScriptError] = []
        let handlers = program.handlers.values.flatMap { $0 }.sorted { $0.line < $1.line }
        for handler in handlers where !known.contains(handler.event) {
            let nearest = known.min {
                ScriptInterpreter.editDistance(handler.event, $0) < ScriptInterpreter.editDistance(handler.event, $1)
            }
            if let nearest, ScriptInterpreter.editDistance(handler.event, nearest) <= 2 {
                problems.append(ScriptError(line: handler.line, kind: .syntax,
                                            message: L("“on {}” never happens. Did you mean “on {}”?", handler.event, nearest)))
            } else {
                problems.append(ScriptError(line: handler.line, kind: .syntax,
                                            message: L("“on {}” never happens. The events are: {}.", handler.event, known.joined(separator: ", "))))
            }
        }
        return problems
    }

    // MARK: Round

    func beginRound() {
        let isRestart = hasStarted
        if let interpreter { output.append(contentsOf: interpreter.drainOutput()) }

        hasStarted = true
        roundStartedAt = clock
        lastTick = clock
        lastNPCStep = clock
        timers.removeAll()
        globalUI.removeAll()
        globalUIOrder.removeAll()
        lastTouch.removeAll()
        deferredUpdates.removeAll()
        settings = Settings()
        weapons = WeaponSpec.presets

        for state in orderedStates where state.isNPC {
            states[state.peer] = nil
            rosterChanged = true
        }
        for state in states.values {
            if state.profile != state.originalProfile || state.isHidden {
                machine.updateProfile(state.originalProfile, for: state.peer)
                rosterChanged = true
            }
            state.reset()
        }

        if isRestart {
            restoreOriginalWorld()
            // Whatever the last round put on screens and in hands goes.
            for effect in [ScriptEffect.clearUI, .camera(.standard), .equip(nil), .movement(.normal),
                           .interface(controls: true, defaultUI: true), .fade(color: nil, seconds: 0)] {
                pending.append(broadcast(.script(effect)))
            }
        }

        loadScript()
        run(.start, [])
        for state in orderedStates where !isRoundOver && !state.isNPC {
            welcome(state, replayingScreen: false)
            // Saved data survives a restarted round; `on loaded` runs again
            // so the new round can read it the same way the first one did.
            if state.saved != nil, !isRoundOver { run(.loaded, [object(for: state)]) }
        }
    }

    /// Puts back every block and setting a script changed, as deltas.
    private func restoreOriginalWorld() {
        let current = world
        let originalIDs = Set(originalWorld.blocks.map(\.id))
        for block in current.blocks where !originalIDs.contains(block.id) {
            queue(.remove(blockID: block.id))
        }
        for block in originalWorld.blocks {
            if let now = current.block(id: block.id) {
                if now != block { queue(.update(block)) }
            } else {
                queue(.insert(block))
            }
        }
        if current.environment != originalWorld.environment {
            queue(.environment(originalWorld.environment))
        }
    }

    private func loadScript() {
        interpreter = nil
        compileErrors = []
        fileNames = []
        guard world.hasScript else { return }

        let bundle: ScriptBundle
        switch ScriptBundle.compile(world.scripts) {
        case let .failure(errors):
            compileErrors = errors
            errors.forEach(report)
            return
        case let .success(compiled):
            bundle = compiled
        }

        fileNames = bundle.fileNames
        let interpreter = ScriptInterpreter(program: bundle.program, seed: seed, limits: scriptLimits)
        interpreter.resolver = self
        installGameAPI(on: interpreter)
        self.interpreter = interpreter
        do {
            try interpreter.start()
        } catch {
            // The top level failed part-way. Handlers may still work, so the
            // script stays loaded and the error is shown.
            report(error)
        }
    }

    /// A player arriving: the shared screen elements they missed, then the
    /// script's `on join`.
    private func welcome(_ state: PlayerState, replayingScreen: Bool) {
        if replayingScreen {
            for id in globalUIOrder {
                guard let element = globalUI[id] else { continue }
                send(state, .script(.ui(element)))
            }
        }
        run(.join, [object(for: state)])
    }

    private func touched(peer: PeerID, blockID: UUID) {
        guard hasStarted, !isRoundOver, let state = states[peer] else { return }
        touched(state, blockID: blockID)
    }

    func touched(_ state: PlayerState, blockID: UUID) {
        guard hasHandler(.touch), state.isAlive, world.block(id: blockID) != nil else { return }
        let key = TouchKey(peer: state.peer, block: blockID)
        if let last = lastTouch[key], clock - last < Limits.touchInterval { return }
        lastTouch[key] = clock
        run(.touch, [object(for: state), blockObject(blockID)])
    }

    // MARK: Combat

    func fire(_ state: PlayerState, origin: Vec3, direction: Vec3) {
        guard state.isAlive, var armed = state.armed, let feet = position(of: state) else { return }
        armed.advance(to: clock)
        if let refusal = armed.refusal(at: clock, origin: origin, direction: direction, shooterFeet: feet,
                                       scale: state.profile.height) {
            state.armed = armed
            // The client thought it could shoot; show it why not.
            if refusal == .reloading { sendAmmo(state) }
            return
        }
        armed.shoot(at: clock)
        state.armed = armed

        let aimed = Hitscan.spread(direction, degrees: armed.weapon.spread, random: &random)
        let result = cast(from: origin, direction: aimed, range: armed.weapon.range, ignoring: state.peer)

        pending.append(broadcast(.script(.tracer(from: origin, to: result.point))))
        send(state, .playSound(name: SoundCue.shoot.rawValue))
        sendAmmo(state)
        if armed.isReloading {
            send(state, .playSound(name: SoundCue.reload.rawValue))
        }

        run(.fire, [object(for: state)])

        switch result.target {
        case let .player(victimPeer):
            guard let victim = states[victimPeer] else { return }
            hit(victim, by: state, damage: armed.weapon.damage)
        case let .block(blockID):
            run(.hitBlock, [object(for: state), blockObject(blockID)])
        case .nothing:
            break
        }
    }

    /// A ray through the world, against every standing character and every
    /// solid block.
    func cast(from origin: Vec3, direction: Vec3, range: Float, ignoring shooter: PeerID?) -> Hitscan.Result {
        var targets: [(peer: PeerID, position: Vec3)] = []
        var scales: [PeerID: Float] = [:]
        for other in states.values where other.isAlive && other.peer != shooter {
            guard let feet = position(of: other) else { continue }
            targets.append((other.peer, feet))
            scales[other.peer] = other.profile.height
        }
        return Hitscan.cast(from: origin, direction: direction, range: range,
                            shooter: shooter ?? PeerID(), players: targets, blocks: solidBlocks(), scales: scales)
    }

    private func hit(_ victim: PlayerState, by attacker: PlayerState, damage: Double) {
        guard victim.isAlive else { return }
        if !settings.friendlyFire, !victim.team.isEmpty, victim.team == attacker.team { return }

        var amount = damage
        // `on hit` may change the damage by returning a number: 0 cancels it,
        // double it for a headshot rule, whatever the game wants.
        if let returned = run(.hit, [object(for: victim), object(for: attacker), .number(damage)]),
           case let .number(changed) = returned, changed.isFinite {
            amount = changed
        }
        guard amount > 0, victim.isAlive else { return }

        let knockedOut = applyDamage(amount, to: victim, from: attacker)
        send(attacker, .script(.hitMarker(killed: knockedOut)))
        send(attacker, .playSound(name: SoundCue.hit.rawValue))
    }

    /// Returns true when the damage knocked them out.
    @discardableResult
    func applyDamage(_ amount: Double, to victim: PlayerState, from attacker: PlayerState?) -> Bool {
        guard victim.isAlive, amount > 0 else { return false }
        victim.health = Swift.max(0, victim.health - amount)
        sendHealth(victim)
        send(victim, .script(.damageFlash))
        send(victim, .playSound(name: SoundCue.hurt.rawValue))
        if victim.health <= 0 {
            knockOut(victim, by: attacker)
            return true
        }
        return false
    }

    func knockOut(_ victim: PlayerState, by attacker: PlayerState?) {
        guard victim.isAlive else { return }
        victim.isAlive = false
        victim.health = 0
        victim.respawnAt = settings.respawnTime >= 0 && !victim.isNPC ? clock + settings.respawnTime : nil
        sendHealth(victim)
        send(victim, .script(.movement(MovementScale(speed: 0, jump: 0, gravity: victim.movement.gravity, frozen: true))))
        send(victim, .playSound(name: SoundCue.defeat.rawValue))
        run(.death, [object(for: victim), attacker.map { object(for: $0) } ?? .null])
        // An NPC that stays down after its `on death` is gone. One the
        // script brought back with `respawn()` stays.
        if victim.isNPC, !victim.isAlive, states[victim.peer] != nil {
            removeNPC(victim)
        }
    }

    func respawn(_ state: PlayerState) {
        state.isAlive = true
        state.respawnAt = nil
        state.health = state.maxHealth
        if let weapon = state.armed?.weapon { state.armed = ArmedState(weapon: weapon) }
        let home = state.isNPC ? (state.home ?? .zero) : machine.respawnPoint(for: state.peer)
        teleport(state, to: home)
        sendHealth(state)
        send(state, .script(.movement(state.movement)))
        if state.armed != nil { sendAmmo(state) }
        run(.respawn, [object(for: state)])
    }

    func solidBlocks() -> [(id: UUID, bounds: BoundingBox)] {
        worldIndex.solidBlocks
    }

    // MARK: NPCs

    /// Walks every NPC toward its goal with the same collision the players
    /// use, so an NPC climbs the same steps and stops at the same walls.
    private func stepNPCs() {
        let step = Float(Swift.min(clock - (lastNPCStep ?? clock), 0.1))
        lastNPCStep = clock
        guard step > 0 else { return }
        let config = MovementConfig.default
        let gravityScale = worldGravityScale
        // One index for every NPC this step: NPCs do not move blocks.
        let index = worldIndex

        for state in orderedStates where state.isNPC {
            guard var body = state.body else { continue }
            let still = !state.isAlive || state.movement.frozen

            var desired = Vec3.zero
            if !still, let target = goalPosition(of: state) {
                let offset = Vec3(target.x - body.position.x, 0, target.z - body.position.z)
                let arrive: Float = state.isFollowing ? 1.6 : 0.25
                if offset.length > arrive {
                    desired = offset.normalized * (config.walkSpeed * state.movement.speed)
                } else if !state.isFollowing {
                    state.goal = .none
                }
            }

            var velocity = Vec3(desired.x, body.velocity.y, desired.z)
            if state.wantsJump, body.isGrounded, !still {
                velocity.y = config.jumpSpeed * state.movement.jump
            } else {
                velocity.y = Swift.max(config.maxFallSpeed, velocity.y + config.gravity * gravityScale * state.movement.gravity * step)
            }
            state.wantsJump = false

            let result = WorldCollider.resolve(position: body.position, velocity: velocity,
                                               body: CharacterBody(radius: 0.4 * state.profile.height,
                                                                   height: 1.8 * state.profile.height),
                                               index: index, deltaTime: step)
            // Walking into a step it cannot walk up: hop, as a player would.
            let wanted = Vec3(desired.x, 0, desired.z).length
            let got = Vec3(result.velocity.x, 0, result.velocity.z).length
            if wanted > 0.5, got < wanted * 0.3, result.isGrounded { state.wantsJump = true }

            let moved = result.position.distance(to: body.position) > 0.005
            body.position = result.position
            body.velocity = result.velocity
            body.isGrounded = result.isGrounded
            if desired.lengthSquared > 0.01 {
                body.yawDegrees = atan2(desired.x, -desired.z) * 180 / .pi
            }
            state.body = body
            if moved || state.needsTransformSend {
                npcTransforms[state.peer] = PlayerTransformPayload(snapshot: body)
                state.needsTransformSend = false
            }

            for blockID in result.touchedBlockIDs { touched(state, blockID: blockID) }

            if body.position.y < world.environment.killPlaneHeight, state.isAlive {
                knockOut(state, by: nil)
            }
        }
    }

    private func goalPosition(of state: PlayerState) -> Vec3? {
        switch state.goal {
        case .none: return nil
        case let .point(point): return point
        case let .character(peer):
            guard let other = states[peer], other.isAlive else { return nil }
            return position(of: other)
        }
    }

    /// The world's gravity relative to Earth's, for movement tuned at 1 g.
    var worldGravityScale: Float {
        let scale = world.environment.gravity / -9.81
        return scale.isFinite ? Swift.min(Swift.max(scale, 0), 5) : 1
    }

    func removeNPC(_ state: PlayerState) {
        guard state.isNPC else { return }
        states[state.peer] = nil
        npcTransforms[state.peer] = nil
        lastTouch = lastTouch.filter { $0.key.peer != state.peer }
        rosterChanged = true
    }

    // MARK: Timers

    private func runDueTimers() {
        let due = timers.filter { $0.due <= clock }.sorted { $0.due < $1.due }.map(\.id)
        for id in due {
            guard !isRoundOver, let index = timers.firstIndex(where: { $0.id == id }) else { continue }
            let timer = timers[index]
            if let interval = timer.interval {
                let next = timer.due + interval
                timers[index].due = next > clock ? next : clock + interval
            } else {
                timers.remove(at: index)
            }
            do {
                try interpreter?.invoke(timer.callback, [], line: timer.line)
            } catch {
                report(error)
            }
        }
    }

    /// Sends the final position of blocks whose animated move has finished.
    private func flushDeferredUpdates() {
        guard !deferredUpdates.isEmpty else { return }
        let due = deferredUpdates.filter { $0.due <= clock }
        deferredUpdates.removeAll { $0.due <= clock }
        for item in due {
            if let block = world.block(id: item.blockID) { pendingDeltas.append(.update(block)) }
        }
    }

    // MARK: Sending state to players

    func sendAmmo(_ state: PlayerState) {
        guard let armed = state.armed else { return }
        send(state, .script(.ammo(current: armed.ammo, magazine: armed.weapon.magazine, reloading: armed.isReloading)))
    }

    func sendHealth(_ state: PlayerState) {
        send(state, .script(.health(current: state.health, maximum: state.maxHealth)))
    }

    /// An effect for one person. NPCs have no screen, so theirs go nowhere.
    func send(_ state: PlayerState, _ action: EventAction) {
        guard !state.isNPC else { return }
        pending.append(Effect(ruleID: nil, targetPeerID: state.peer, action: action))
    }

    func broadcast(_ action: EventAction) -> Effect {
        Effect(ruleID: nil, targetPeerID: nil, action: action)
    }

    /// Changes the map for everyone: the rule machine's copy now, every
    /// iPad's copy when the host sends the delta on.
    func queue(_ delta: WorldDelta) {
        machine.apply(delta)
        pendingDeltas.append(delta)
    }

    func teleport(_ state: PlayerState, to position: Vec3) {
        if state.isNPC {
            state.body?.position = position
            state.body?.velocity = .zero
            state.needsTransformSend = true
            if let body = state.body { npcTransforms[state.peer] = PlayerTransformPayload(snapshot: body) }
            return
        }
        // Moved here too, not only on their screen: until their next
        // transform arrives, shots and proximity rules must look for them
        // where they now are.
        let yaw = machine.player(state.peer)?.yawDegrees ?? 0
        machine.updateTransform(PlayerTransformPayload(peerID: state.peer, position: position, yawDegrees: yaw))
        send(state, .teleportPlayer(to: position))
    }

    func setScore(_ state: PlayerState, to newScore: Int) {
        if state.isNPC {
            state.npcScore = newScore
            return
        }
        guard let old = machine.player(state.peer)?.score, old != newScore else { return }
        send(state, .awardPoints(newScore - old))
        pending.append(contentsOf: machine.handle(.scoreChanged(peer: state.peer, newScore: newScore)))
    }

    /// Changes how a character looks, for everyone.
    func updateProfile(_ state: PlayerState, _ change: (inout AvatarProfile) -> Void) {
        var profile = state.profile
        change(&profile)
        guard profile != state.profile else { return }
        state.profile = profile
        if state.isNPC {
            state.body?.profile = profile
        } else {
            machine.updateProfile(profile, for: state.peer)
        }
        state.name = profile.displayName
        rosterChanged = true
    }

    func snapshot(of state: PlayerState) -> PlayerSnapshot? {
        state.isNPC ? state.body : machine.player(state.peer)
    }

    func position(of state: PlayerState) -> Vec3? {
        snapshot(of: state)?.position
    }

    // MARK: Plumbing

    func collect(_ body: () -> Void) -> [Effect] {
        body()
        defer { pending.removeAll() }
        return pending
    }

    var orderedStates: [PlayerState] {
        states.values.sorted { $0.joinOrder < $1.joinOrder }
    }

    func hasHandler(_ event: Event) -> Bool {
        interpreter?.hasHandler(event.rawValue) ?? false
    }

    /// Runs a handler, recording rather than propagating its errors: one
    /// broken handler must not stop the game for everyone.
    @discardableResult
    func run(_ event: Event, _ arguments: [ScriptValue]) -> ScriptValue? {
        guard let interpreter, interpreter.hasHandler(event.rawValue) else { return nil }
        do {
            return try interpreter.run(event.rawValue, arguments)
        } catch {
            report(error)
            return nil
        }
    }

    func report(_ error: Error) {
        let raw = error as? ScriptError ?? ScriptError(line: 0, kind: .runtime, message: String(describing: error))
        let scriptError = raw.resolved(files: fileNames)
        let key = "\(scriptError.file ?? "")|\(scriptError.line)|\(scriptError.message)"
        guard reportedErrors.insert(key).inserted else { return }
        if newErrors.count < 50 { newErrors.append(scriptError) }
    }

    /// The element with that id on this player's screen, theirs or everyone's.
    func element(_ id: String, visibleTo state: PlayerState) -> UIElement? {
        guard let element = state.ui[id] ?? globalUI[id], element.visible else { return nil }
        return element
    }

    // MARK: Objects

    func object(for state: PlayerState) -> ScriptValue {
        .object(ScriptObject(kind: state.isNPC ? "npc" : "player", id: state.peer.raw.uuidString, displayName: state.name))
    }

    func blockObject(_ id: UUID) -> ScriptValue {
        guard let block = world.block(id: id) else { return .null }
        return .object(ScriptObject(kind: "block", id: id.uuidString, displayName: block.name))
    }

    func character(_ object: ScriptObject) -> PlayerState? {
        guard object.kind == "player" || object.kind == "npc", let uuid = UUID(uuidString: object.id) else { return nil }
        return states[PeerID(uuid)]
    }

    func blockID(_ object: ScriptObject) -> UUID? {
        guard object.kind == "block", let uuid = UUID(uuidString: object.id), worldIndex.entry(for: uuid) != nil else { return nil }
        return uuid
    }
}

// MARK: - Per-character state

extension GameRuntime {

    /// What the host knows about one character — a person or an NPC —
    /// beyond their avatar.
    final class PlayerState {
        enum Goal: Equatable {
            case none
            case point(Vec3)
            case character(PeerID)
        }

        let peer: PeerID
        let joinOrder: Int
        let isNPC: Bool
        var name: String
        var profile: AvatarProfile
        /// How they looked on arrival, restored when the round restarts.
        var originalProfile: AvatarProfile
        var health: Double = 100
        var maxHealth: Double = 100
        var team = ""
        var isAlive = true
        var respawnAt: Double?
        var armed: ArmedState?
        var camera: CameraSettings = .standard
        var movement: MovementScale = .normal
        var showsControls = true
        var showsDefaultUI = true
        var isHidden = false
        /// This player's own screen elements, by id.
        var ui: [String: UIElement] = [:]
        /// Values the script stored on the character: `p.kills = 3`.
        var custom: [String: ScriptValue] = [:]
        /// What this player has saved in this world, once it has arrived from
        /// their iPad. Nil until then — and `p.save` waits for it, or the first
        /// save of a session would overwrite everything saved before.
        var saved: SaveData?
        /// Changed since it was last sent back to their iPad.
        var saveChanged = false
        var lastSaveSent = -Double.infinity

        // NPCs only.
        var body: PlayerSnapshot?
        var home: Vec3?
        var goal: Goal = .none
        var wantsJump = false
        var needsTransformSend = false
        var npcScore = 0

        var isFollowing: Bool {
            if case .character = goal { return true }
            return false
        }

        init(peer: PeerID, joinOrder: Int, name: String, profile: AvatarProfile, isNPC: Bool = false) {
            self.peer = peer
            self.joinOrder = joinOrder
            self.name = name
            self.profile = profile
            self.originalProfile = profile
            self.isNPC = isNPC
        }

        func reset() {
            health = 100
            maxHealth = 100
            team = ""
            isAlive = true
            respawnAt = nil
            armed = nil
            camera = .standard
            movement = .normal
            showsControls = true
            showsDefaultUI = true
            isHidden = false
            profile = originalProfile
            name = originalProfile.displayName
            ui.removeAll()
            custom.removeAll()
        }
    }

    struct ScriptTimer {
        let id: Int
        var due: Double
        /// Set for `every`; nil for a one-off `after`.
        let interval: Double?
        let callback: ScriptValue
        let line: Int
    }

    struct TouchKey: Hashable {
        let peer: PeerID
        let block: UUID
    }
}
