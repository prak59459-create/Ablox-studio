import Foundation

/// Everything the host decides about a game in progress: the world's rules
/// (`EventMachine`) and the world's script.
///
/// The two halves are one object because they share one world and one set of
/// players. A script that sets `p.score` has to trip the rule that ends the
/// round at 10 points; a rule that teleports a player has to move them where a
/// script's shot will look for them. Two objects would each need a copy of the
/// other's state, and a copy is a second thing to keep right.
///
/// Like `EventMachine`, it has no clock and no networking: time and inputs are
/// passed in and effects come out. That is what lets a whole 1v1 match be
/// played in a unit test — see `GameRuntimeTests`.
public final class GameRuntime {

    public typealias Effect = EventMachine.Effect

    /// The handlers a script can write. Anything else after `on` is a typo,
    /// and `GameRuntime.check` says so.
    public enum Event: String, CaseIterable, Sendable {
        case start, tick, join, leave, touch, tap, fire, hit
        case hitBlock = "hit_block"
        case death, respawn, button
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

    public enum Limits {
        /// Timers alive at once. `every(0.1, …)` inside `on tick` would
        /// otherwise add ten timers a second, forever.
        public static let maximumTimers = 200
        public static let minimumRepeatInterval = 0.1
        public static let maximumCustomWeapons = 32
        /// How often `on touch` fires for the same player and block. Contact
        /// is reported on every physics step while standing on something.
        public static let touchInterval = 0.5
        public static let maximumHealth: Double = 100_000
        public static let maximumMovementMultiplier: Float = 3
    }

    // MARK: State

    public private(set) var machine: EventMachine
    public private(set) var settings = Settings()
    /// The script's syntax error, when it has one. The rules still run.
    public private(set) var compileError: ScriptError?
    public private(set) var hasStarted = false

    public var world: WorldDocument { machine.world }
    public var roster: [PlayerSnapshot] { machine.roster }
    public var players: [PeerID: PlayerSnapshot] { machine.players }
    public var isRoundOver: Bool { machine.isRoundOver }
    public var isScriptRunning: Bool { interpreter != nil }

    private var interpreter: ScriptInterpreter?
    private var states: [PeerID: PlayerState] = [:]
    private var joinCounter = 0
    private var clock: Double
    private var roundStartedAt: Double = 0
    private var lastTick: Double?
    private var timers: [ScriptTimer] = []
    private var nextTimerID = 1
    private var weapons: [String: WeaponSpec] = WeaponSpec.presets
    private var globalHUD: [String: HUDElement] = [:]
    private var globalHUDOrder: [String] = []
    private var lastTouch: [TouchKey: Double] = [:]
    private var random: ScriptRandom
    private let seed: UInt64

    private var pending: [Effect] = []
    private var newErrors: [ScriptError] = []
    private var reportedErrors: Set<String> = []
    private var output: [String] = []

    public init(world: WorldDocument, startTime: Double = 0, seed: UInt64 = 1) {
        self.machine = EventMachine(world: world, startTime: startTime)
        self.clock = startTime
        self.seed = seed
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
                return
            }
            machine.addPlayer(snapshot)
            let state = PlayerState(peer: snapshot.peerID, joinOrder: joinCounter, name: snapshot.profile.displayName)
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
                // Before removing them, so the handler can still read their
                // name and score.
                run(.leave, [object(for: state)])
            }
            machine.removePlayer(peer)
            states[peer] = nil
            lastTouch = lastTouch.filter { $0.key.peer != peer }
        }
    }

    public func updateTransform(_ payload: PlayerTransformPayload) {
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
            pending.append(contentsOf: machine.advance(to: time))
            guard hasStarted, !isRoundOver else { return }

            for state in orderedStates {
                if state.armed?.advance(to: clock) == true {
                    sendAmmo(state)
                }
                if !state.isAlive, let due = state.respawnAt, clock >= due {
                    respawn(state)
                }
            }

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
            guard hasStarted, !isRoundOver, let state = states[peer] else { return }
            switch input {
            case let .fire(origin, direction):
                fire(state, origin: origin, direction: direction)
            case let .button(id):
                // Only a button that player can actually see. Otherwise any
                // client could press any button, including one the script
                // only shows to the winner.
                guard isButton(id, visibleTo: state) else { return }
                run(.button, [object(for: state), .string(id)])
            case .reload:
                guard state.isAlive, state.armed?.startReload(at: clock) == true else { return }
                sendAmmo(state)
                pending.append(personal(state.peer, .playSound(name: SoundCue.reload.rawValue)))
            }
        }
    }

    public func apply(_ delta: WorldDelta) {
        machine.apply(delta)
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

    /// Everything wrong with a script that can be found without running it:
    /// the syntax error, or handlers for events that never happen.
    ///
    /// Studio's Check button. An `on joni(p)` parses perfectly and then
    /// silently never runs, which is the worst kind of bug to hunt.
    public static func check(_ source: String) -> [ScriptError] {
        let program: ScriptProgram
        do {
            program = try ScriptParser.parse(source)
        } catch let error as ScriptError {
            return [error]
        } catch {
            return [ScriptError(line: 1, kind: .syntax, message: String(describing: error))]
        }

        let known = Event.allCases.map(\.rawValue)
        var problems: [ScriptError] = []
        for handler in program.handlers.values.sorted(by: { $0.line < $1.line }) where !known.contains(handler.event) {
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

    private func beginRound() {
        let isRestart = hasStarted
        if let interpreter { output.append(contentsOf: interpreter.drainOutput()) }

        hasStarted = true
        roundStartedAt = clock
        lastTick = clock
        timers.removeAll()
        globalHUD.removeAll()
        globalHUDOrder.removeAll()
        lastTouch.removeAll()
        settings = Settings()
        weapons = WeaponSpec.presets
        for state in states.values { state.reset() }

        if isRestart {
            // Whatever the last round put on screens and in hands goes.
            for effect in [ScriptEffect.clearHUD, .camera(.thirdPerson), .equip(nil), .movement(speed: 1, jump: 1)] {
                pending.append(broadcast(.script(effect)))
            }
        }

        loadScript()
        run(.start, [])
        for state in orderedStates where !isRoundOver {
            welcome(state, replayingScreen: false)
        }
    }

    private func loadScript() {
        interpreter = nil
        compileError = nil
        guard world.hasScript, let source = world.script else { return }

        let program: ScriptProgram
        do {
            program = try ScriptParser.parse(source)
        } catch {
            let scriptError = error as? ScriptError ?? ScriptError(line: 1, kind: .syntax, message: String(describing: error))
            compileError = scriptError
            report(scriptError)
            return
        }

        let interpreter = ScriptInterpreter(program: program, seed: seed)
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
            for id in globalHUDOrder {
                guard let element = globalHUD[id] else { continue }
                pending.append(personal(state.peer, .script(.hud(element))))
            }
        }
        run(.join, [object(for: state)])
    }

    private func touched(peer: PeerID, blockID: UUID) {
        guard hasStarted, !isRoundOver, hasHandler(.touch),
              let state = states[peer], state.isAlive,
              world.block(id: blockID) != nil else { return }
        let key = TouchKey(peer: peer, block: blockID)
        if let last = lastTouch[key], clock - last < Limits.touchInterval { return }
        lastTouch[key] = clock
        run(.touch, [object(for: state), blockObject(blockID)])
    }

    // MARK: Combat

    private func fire(_ state: PlayerState, origin: Vec3, direction: Vec3) {
        guard state.isAlive, var armed = state.armed, let body = machine.player(state.peer) else { return }
        armed.advance(to: clock)
        if let refusal = armed.refusal(at: clock, origin: origin, direction: direction, shooterFeet: body.position) {
            state.armed = armed
            // The client thought it could shoot; show it why not.
            if refusal == .reloading { sendAmmo(state) }
            return
        }
        armed.shoot(at: clock)
        state.armed = armed

        let aimed = Hitscan.spread(direction, degrees: armed.weapon.spread, random: &random)
        let result = Hitscan.cast(
            from: origin,
            direction: aimed,
            range: armed.weapon.range,
            shooter: state.peer,
            players: states.values.compactMap { other in
                guard other.isAlive, other.peer != state.peer, let snapshot = machine.player(other.peer) else { return nil }
                return (other.peer, snapshot.position)
            },
            blocks: solidBlocks()
        )

        pending.append(broadcast(.script(.tracer(from: origin, to: result.point))))
        pending.append(personal(state.peer, .playSound(name: SoundCue.shoot.rawValue)))
        sendAmmo(state)
        if armed.isReloading {
            pending.append(personal(state.peer, .playSound(name: SoundCue.reload.rawValue)))
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
        pending.append(personal(attacker.peer, .script(.hitMarker(killed: knockedOut))))
        pending.append(personal(attacker.peer, .playSound(name: SoundCue.hit.rawValue)))
    }

    /// Returns true when the damage knocked them out.
    @discardableResult
    private func applyDamage(_ amount: Double, to victim: PlayerState, from attacker: PlayerState?) -> Bool {
        guard victim.isAlive, amount > 0 else { return false }
        victim.health = Swift.max(0, victim.health - amount)
        sendHealth(victim)
        pending.append(personal(victim.peer, .script(.damageFlash)))
        pending.append(personal(victim.peer, .playSound(name: SoundCue.hurt.rawValue)))
        if victim.health <= 0 {
            knockOut(victim, by: attacker)
            return true
        }
        return false
    }

    private func knockOut(_ victim: PlayerState, by attacker: PlayerState?) {
        guard victim.isAlive else { return }
        victim.isAlive = false
        victim.health = 0
        victim.respawnAt = settings.respawnTime >= 0 ? clock + settings.respawnTime : nil
        sendHealth(victim)
        pending.append(personal(victim.peer, .script(.movement(speed: 0, jump: 0))))
        pending.append(personal(victim.peer, .playSound(name: SoundCue.defeat.rawValue)))
        run(.death, [object(for: victim), attacker.map { object(for: $0) } ?? .null])
    }

    private func respawn(_ state: PlayerState) {
        state.isAlive = true
        state.respawnAt = nil
        state.health = state.maxHealth
        if let weapon = state.armed?.weapon { state.armed = ArmedState(weapon: weapon) }
        teleport(state, to: machine.respawnPoint(for: state.peer))
        sendHealth(state)
        pending.append(personal(state.peer, .script(.movement(speed: state.speed, jump: state.jump))))
        if state.armed != nil { sendAmmo(state) }
        run(.respawn, [object(for: state)])
    }

    private func solidBlocks() -> [(id: UUID, bounds: BoundingBox)] {
        world.blocks.compactMap { block in
            guard block.isVisible, block.hasCollision, let bounds = world.worldBounds(of: block.id) else { return nil }
            return (block.id, bounds)
        }
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

    // MARK: Sending state to players

    private func sendAmmo(_ state: PlayerState) {
        guard let armed = state.armed else { return }
        pending.append(personal(state.peer, .script(.ammo(
            current: armed.ammo, magazine: armed.weapon.magazine, reloading: armed.isReloading
        ))))
    }

    private func sendHealth(_ state: PlayerState) {
        pending.append(personal(state.peer, .script(.health(current: state.health, maximum: state.maxHealth))))
    }

    private func teleport(_ state: PlayerState, to position: Vec3) {
        // Moved here too, not only on their screen: until their next
        // transform arrives, shots and proximity rules must look for them
        // where they now are.
        let yaw = machine.player(state.peer)?.yawDegrees ?? 0
        machine.updateTransform(PlayerTransformPayload(peerID: state.peer, position: position, yawDegrees: yaw))
        pending.append(personal(state.peer, .teleportPlayer(to: position)))
    }

    private func setScore(_ state: PlayerState, to newScore: Int) {
        guard let old = machine.player(state.peer)?.score, old != newScore else { return }
        pending.append(personal(state.peer, .awardPoints(newScore - old)))
        pending.append(contentsOf: machine.handle(.scoreChanged(peer: state.peer, newScore: newScore)))
    }

    private func personal(_ peer: PeerID, _ action: EventAction) -> Effect {
        Effect(ruleID: nil, targetPeerID: peer, action: action)
    }

    private func broadcast(_ action: EventAction) -> Effect {
        Effect(ruleID: nil, targetPeerID: nil, action: action)
    }

    // MARK: Plumbing

    private func collect(_ body: () -> Void) -> [Effect] {
        body()
        defer { pending.removeAll() }
        return pending
    }

    private var orderedStates: [PlayerState] {
        states.values.sorted { $0.joinOrder < $1.joinOrder }
    }

    private func hasHandler(_ event: Event) -> Bool {
        interpreter?.hasHandler(event.rawValue) ?? false
    }

    /// Runs a handler, recording rather than propagating its errors: one
    /// broken handler must not stop the game for everyone.
    @discardableResult
    private func run(_ event: Event, _ arguments: [ScriptValue]) -> ScriptValue? {
        guard let interpreter, interpreter.hasHandler(event.rawValue) else { return nil }
        do {
            return try interpreter.run(event.rawValue, arguments)
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        let scriptError = error as? ScriptError ?? ScriptError(line: 0, kind: .runtime, message: String(describing: error))
        guard reportedErrors.insert("\(scriptError.line)|\(scriptError.message)").inserted else { return }
        if newErrors.count < 50 { newErrors.append(scriptError) }
    }

    private func isButton(_ id: String, visibleTo state: PlayerState) -> Bool {
        let element = state.hud[id] ?? globalHUD[id]
        if case .button = element?.kind { return true }
        return false
    }

    // MARK: Objects

    private func object(for state: PlayerState) -> ScriptValue {
        .object(ScriptObject(kind: "player", id: state.peer.raw.uuidString, displayName: state.name))
    }

    private func blockObject(_ id: UUID) -> ScriptValue {
        guard let block = world.block(id: id) else { return .null }
        return .object(ScriptObject(kind: "block", id: id.uuidString, displayName: block.name))
    }

    private func playerState(_ object: ScriptObject) -> PlayerState? {
        guard object.kind == "player", let uuid = UUID(uuidString: object.id) else { return nil }
        return states[PeerID(uuid)]
    }

    private func blockID(_ object: ScriptObject) -> UUID? {
        guard object.kind == "block", let uuid = UUID(uuidString: object.id), world.block(id: uuid) != nil else { return nil }
        return uuid
    }
}

// MARK: - Per-player state

extension GameRuntime {

    /// What the host knows about one player beyond their avatar.
    final class PlayerState {
        let peer: PeerID
        let joinOrder: Int
        var name: String
        var health: Double = 100
        var maxHealth: Double = 100
        var team = ""
        var isAlive = true
        var respawnAt: Double?
        var armed: ArmedState?
        var camera: CameraMode = .thirdPerson
        var speed: Float = 1
        var jump: Float = 1
        /// This player's own screen elements, by id.
        var hud: [String: HUDElement] = [:]
        /// Values the script stored on the player: `p.kills = 3`.
        var custom: [String: ScriptValue] = [:]

        init(peer: PeerID, joinOrder: Int, name: String) {
            self.peer = peer
            self.joinOrder = joinOrder
            self.name = name
        }

        func reset() {
            health = 100
            maxHealth = 100
            team = ""
            isAlive = true
            respawnAt = nil
            armed = nil
            camera = .thirdPerson
            speed = 1
            jump = 1
            hud.removeAll()
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

// MARK: - The game API scripts see

extension GameRuntime: ScriptObjectResolver {

    /// Every global the game adds on top of the standard library.
    public static let gameAPINames: [String] = [
        "game", "players", "block", "blocks", "distance", "time",
        "after", "every", "cancel",
        "announce", "sound", "end_round",
        "weapon", "hud_text", "hud_bar", "hud_button", "hud_remove", "hud_clear"
    ]

    /// Members of a player, for Studio's reference.
    public static let playerMemberNames: [String] = [
        "name", "id", "health", "max_health", "alive", "score", "team", "position", "yaw",
        "weapon", "ammo", "camera", "speed", "jump",
        "give", "take", "reload", "teleport", "damage", "heal", "kill", "respawn", "message", "sound",
        "hud_text", "hud_bar", "hud_button", "hud_remove", "hud_clear"
    ]

    public static let blockMemberNames: [String] = [
        "name", "id", "position", "visible", "solid", "color", "tags", "move"
    ]

    fileprivate func installGameAPI(on interpreter: ScriptInterpreter) {
        interpreter.defineValue("game", .object(ScriptObject(kind: "game", id: "game", displayName: "game")))

        interpreter.define("players") { [unowned self] _, _ in
            .list(ScriptList(self.orderedStates.map { self.object(for: $0) }))
        }

        interpreter.define("block") { [unowned self] arguments, _ in
            let name = (arguments.first ?? .null).displayText
            let match = self.world.blocks.first { $0.name == name }
                ?? self.world.blocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return match.map { self.blockObject($0.id) } ?? .null
        }

        interpreter.define("blocks") { [unowned self] arguments, _ in
            let tag = (arguments.first ?? .null).displayText
            return .list(ScriptList(self.world.blocks(taggedWith: tag).map { self.blockObject($0.id) }))
        }

        interpreter.define("distance") { [unowned self] arguments, line in
            guard arguments.count >= 2 else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "distance", 2))
            }
            let a = try self.position(of: arguments[0], line: line)
            let b = try self.position(of: arguments[1], line: line)
            return .number(Double(a.distance(to: b)))
        }

        interpreter.define("time") { [unowned self] _, _ in
            .number(self.clock - self.roundStartedAt)
        }

        // MARK: Timers

        interpreter.define("after") { [unowned self] arguments, line in
            try self.addTimer(arguments, repeating: false, line: line)
        }
        interpreter.define("every") { [unowned self] arguments, line in
            try self.addTimer(arguments, repeating: true, line: line)
        }
        interpreter.define("cancel") { [unowned self] arguments, _ in
            guard case let .number(id) = arguments.first ?? .null else { return .bool(false) }
            let before = self.timers.count
            self.timers.removeAll { $0.id == Int(id) }
            return .bool(self.timers.count < before)
        }

        // MARK: Everyone

        interpreter.define("announce") { [unowned self] arguments, line in
            let text = try self.shortText(arguments.first ?? .null, line: line)
            let seconds = try self.optionalNumber(arguments, 1, default: 3, line: line)
            self.pending.append(self.broadcast(.announce(message: text, duration: Swift.min(Swift.max(seconds, 0.5), 30))))
            return .null
        }

        interpreter.define("sound") { [unowned self] arguments, line in
            let cue = try self.soundCue(arguments.first ?? .null, line: line)
            self.pending.append(self.broadcast(.playSound(name: cue.rawValue)))
            return .null
        }

        interpreter.define("end_round") { [unowned self] arguments, line in
            let text = arguments.isEmpty ? L("Round over") : try self.shortText(arguments[0], line: line)
            self.pending.append(self.broadcast(.endRound(message: text)))
            self.machine.endRound()
            return .null
        }

        // MARK: Weapons

        interpreter.define("weapon") { [unowned self] arguments, line in
            try self.defineWeapon(arguments, line: line)
        }

        // MARK: Screen, for everyone

        interpreter.define("hud_text") { [unowned self] arguments, line in
            try self.showHUD(try self.hudElement(.text, arguments, line: line), to: nil, line: line)
        }
        interpreter.define("hud_bar") { [unowned self] arguments, line in
            try self.showHUD(try self.hudElement(.bar, arguments, line: line), to: nil, line: line)
        }
        interpreter.define("hud_button") { [unowned self] arguments, line in
            try self.showHUD(try self.hudElement(.button, arguments, line: line), to: nil, line: line)
        }
        interpreter.define("hud_remove") { [unowned self] arguments, _ in
            self.removeHUD((arguments.first ?? .null).displayText, from: nil)
            return .null
        }
        interpreter.define("hud_clear") { [unowned self] _, _ in
            self.clearHUD(for: nil)
            return .null
        }
    }

    // MARK: Members

    public func member(of object: ScriptObject, named name: String, line: Int) throws -> ScriptValue {
        switch object.kind {
        case "player": return try playerMember(object, name, line: line)
        case "block": return try blockMember(object, name, line: line)
        case "game": return try gameMember(name, line: line)
        default: return .null
        }
    }

    public func setMember(of object: ScriptObject, named name: String, to value: ScriptValue, line: Int) throws {
        switch object.kind {
        case "player": try setPlayerMember(object, name, value, line: line)
        case "block": try setBlockMember(object, name, value, line: line)
        case "game": try setGameMember(name, value, line: line)
        default: throw ScriptError(line: line, kind: .runtime, message: L("“{}” cannot be changed here.", name))
        }
    }

    // MARK: Player

    private func playerMember(_ object: ScriptObject, _ name: String, line: Int) throws -> ScriptValue {
        // A player who has left still has a name, so a leave message works.
        guard let state = playerState(object) else {
            switch name {
            case "name": return .string(object.displayName)
            case "alive": return .bool(false)
            default: return .null
            }
        }
        let snapshot = machine.player(state.peer)

        switch name {
        case "name": return .string(state.name)
        case "id": return .string(state.peer.description)
        case "health": return .number(state.health)
        case "max_health": return .number(state.maxHealth)
        case "alive": return .bool(state.isAlive)
        case "score": return .number(Double(snapshot?.score ?? 0))
        case "team": return state.team.isEmpty ? .null : .string(state.team)
        case "position": return positionValue(snapshot?.position ?? .zero)
        case "yaw": return .number(Double(snapshot?.yawDegrees ?? 0))
        case "weapon": return state.armed.map { .string($0.weapon.name) } ?? .null
        case "ammo": return state.armed.map { .number(Double($0.ammo)) } ?? .null
        case "camera": return .string(state.camera.rawValue)
        case "speed": return .number(Double(state.speed))
        case "jump": return .number(Double(state.jump))

        case "give":
            return method(name) { [unowned self] arguments, line in
                let weapon = try self.weaponNamed(arguments.first ?? .null, line: line)
                state.armed = ArmedState(weapon: weapon)
                self.pending.append(self.personal(state.peer, .script(.equip(weapon.clamped))))
                self.sendAmmo(state)
                // A player with a weapon is in a fight, so their health
                // shows from now on rather than after the first hit.
                self.sendHealth(state)
                return .null
            }
        case "take":
            return method(name) { [unowned self] _, _ in
                state.armed = nil
                self.pending.append(self.personal(state.peer, .script(.equip(nil))))
                return .null
            }
        case "reload":
            return method(name) { [unowned self] _, _ in
                if state.armed?.startReload(at: self.clock) == true { self.sendAmmo(state) }
                return .null
            }
        case "teleport":
            return method(name) { [unowned self] arguments, line in
                let target: Vec3
                if arguments.count >= 3 {
                    target = Vec3(
                        Float(try self.number(arguments[0], "teleport", line)),
                        Float(try self.number(arguments[1], "teleport", line)),
                        Float(try self.number(arguments[2], "teleport", line))
                    )
                } else {
                    target = try self.position(of: arguments.first ?? .null, line: line, standingOn: true)
                }
                self.teleport(state, to: target)
                return .null
            }
        case "damage":
            return method(name) { [unowned self] arguments, line in
                let amount = try self.number(arguments.first ?? .null, "damage", line)
                var attacker: PlayerState?
                if arguments.count > 1, case let .object(other) = arguments[1] { attacker = self.playerState(other) }
                self.applyDamage(amount, to: state, from: attacker)
                return .null
            }
        case "heal":
            return method(name) { [unowned self] arguments, line in
                let amount = try self.number(arguments.first ?? .null, "heal", line)
                guard state.isAlive, amount > 0 else { return .null }
                state.health = Swift.min(state.maxHealth, state.health + amount)
                self.sendHealth(state)
                return .null
            }
        case "kill":
            return method(name) { [unowned self] arguments, _ in
                var attacker: PlayerState?
                if case let .object(other) = arguments.first ?? .null { attacker = self.playerState(other) }
                self.knockOut(state, by: attacker)
                return .null
            }
        case "respawn":
            return method(name) { [unowned self] _, _ in
                self.respawn(state)
                return .null
            }
        case "message":
            return method(name) { [unowned self] arguments, line in
                let text = try self.shortText(arguments.first ?? .null, line: line)
                let seconds = try self.optionalNumber(arguments, 1, default: 3, line: line)
                self.pending.append(self.personal(state.peer, .announce(message: text, duration: Swift.min(Swift.max(seconds, 0.5), 30))))
                return .null
            }
        case "sound":
            return method(name) { [unowned self] arguments, line in
                let cue = try self.soundCue(arguments.first ?? .null, line: line)
                self.pending.append(self.personal(state.peer, .playSound(name: cue.rawValue)))
                return .null
            }
        case "hud_text":
            return method(name) { [unowned self] arguments, line in
                try self.showHUD(try self.hudElement(.text, arguments, line: line), to: state, line: line)
            }
        case "hud_bar":
            return method(name) { [unowned self] arguments, line in
                try self.showHUD(try self.hudElement(.bar, arguments, line: line), to: state, line: line)
            }
        case "hud_button":
            return method(name) { [unowned self] arguments, line in
                try self.showHUD(try self.hudElement(.button, arguments, line: line), to: state, line: line)
            }
        case "hud_remove":
            return method(name) { [unowned self] arguments, _ in
                self.removeHUD((arguments.first ?? .null).displayText, from: state)
                return .null
            }
        case "hud_clear":
            return method(name) { [unowned self] _, _ in
                self.clearHUD(for: state)
                return .null
            }

        default:
            return state.custom[name] ?? .null
        }
    }

    private func setPlayerMember(_ object: ScriptObject, _ name: String, _ value: ScriptValue, line: Int) throws {
        guard let state = playerState(object) else { return }   // they left; nothing to change

        switch name {
        case "health":
            let target = Swift.min(Swift.max(try number(value, name, line), 0), state.maxHealth)
            if target < state.health {
                applyDamage(state.health - target, to: state, from: nil)
            } else if state.isAlive {
                state.health = target
                sendHealth(state)
            }
        case "max_health":
            let maximum = Swift.min(Swift.max(try number(value, name, line), 1), Limits.maximumHealth)
            state.maxHealth = maximum
            state.health = Swift.min(state.health, maximum)
            sendHealth(state)
        case "score":
            let score = try number(value, name, line)
            guard score.isFinite, Swift.abs(score) < 1_000_000_000 else {
                throw ScriptError(line: line, kind: .runtime, message: L("That number is too big."))
            }
            setScore(state, to: Int(score.rounded()))
        case "team":
            if case .null = value { state.team = "" } else { state.team = String(value.displayText.prefix(32)) }
        case "camera":
            let text = value.displayText.lowercased()
            guard let mode = CameraMode(rawValue: text) ?? (text == "first_person" ? .firstPerson : text == "third_person" ? .thirdPerson : nil) else {
                throw ScriptError(line: line, kind: .runtime, message: L("“camera” is “first” or “third”, not {}.", value.displayText))
            }
            state.camera = mode
            pending.append(personal(state.peer, .script(.camera(mode))))
        case "speed", "jump":
            let multiplier = Float(Swift.min(Swift.max(try number(value, name, line), 0), Double(Limits.maximumMovementMultiplier)))
            if name == "speed" { state.speed = multiplier } else { state.jump = multiplier }
            if state.isAlive {
                pending.append(personal(state.peer, .script(.movement(speed: state.speed, jump: state.jump))))
            }
        case "ammo":
            guard var armed = state.armed else { return }
            armed.ammo = Swift.min(Swift.max(Int(try number(value, name, line)), 0), armed.weapon.magazine)
            armed.reloadEnds = nil
            state.armed = armed
            sendAmmo(state)
        case "name", "id", "alive", "position", "yaw", "weapon":
            throw ScriptError(line: line, kind: .runtime, message: L("A player’s “{}” cannot be set directly.", name))
        default:
            if Self.playerMemberNames.contains(name) {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” is a function. Call it with ().", name))
            }
            if case .null = value {
                state.custom[name] = nil
            } else {
                guard state.custom[name] != nil || state.custom.count < 64 else {
                    throw ScriptError(line: line, kind: .limit, message: L("Too many values stored on one player."))
                }
                state.custom[name] = value
            }
        }
    }

    // MARK: Block

    private func blockMember(_ object: ScriptObject, _ name: String, line: Int) throws -> ScriptValue {
        guard let id = blockID(object), let block = world.block(id: id) else {
            if name == "name" { return .string(object.displayName) }
            return .null
        }
        switch name {
        case "name": return .string(block.name)
        case "id": return .string(String(id.uuidString.prefix(8)))
        case "position": return positionValue(world.worldPosition(of: id))
        case "visible": return .bool(block.isVisible)
        case "solid": return .bool(block.hasCollision)
        case "color": return .string(block.color.hexString)
        case "tags": return .list(ScriptList(block.tags.map { .string($0) }))
        case "move":
            return method(name) { [unowned self] arguments, line in
                guard arguments.count >= 3 else {
                    throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "move", 3))
                }
                let offset = Vec3(
                    Float(try self.number(arguments[0], "move", line)),
                    Float(try self.number(arguments[1], "move", line)),
                    Float(try self.number(arguments[2], "move", line))
                )
                let seconds = Swift.min(Swift.max(try self.optionalNumber(arguments, 3, default: 0, line: line), 0), 60)
                guard var moved = self.world.block(id: id) else { return .null }
                // The document takes the end position at once, even for an
                // animated move: shots and late joiners must agree on where
                // the block ends up.
                moved.position += offset
                self.machine.apply(.update(moved))
                self.pending.append(self.broadcast(.move(blockID: id, offset: offset, duration: seconds)))
                return .null
            }
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A block has no “{}”.", name))
        }
    }

    private func setBlockMember(_ object: ScriptObject, _ name: String, _ value: ScriptValue, line: Int) throws {
        guard let id = blockID(object), var block = world.block(id: id) else { return }
        switch name {
        case "visible":
            block.isVisible = value.isTruthy
            machine.apply(.update(block))
            pending.append(broadcast(.setVisible(blockID: id, visible: block.isVisible)))
        case "solid":
            block.hasCollision = value.isTruthy
            machine.apply(.update(block))
            pending.append(broadcast(.setCollision(blockID: id, enabled: block.hasCollision)))
        case "color":
            let color = try self.color(value, line: line)
            block.color = color
            machine.apply(.update(block))
            pending.append(broadcast(.tint(blockID: id, color: color, duration: 0)))
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A block’s “{}” cannot be set.", name))
        }
    }

    // MARK: Game

    private func gameMember(_ name: String, line: Int) throws -> ScriptValue {
        switch name {
        case "respawn_time": return .number(settings.respawnTime)
        case "friendly_fire": return .bool(settings.friendlyFire)
        case "time": return .number(clock - roundStartedAt)
        case "round_over": return .bool(isRoundOver)
        default: throw ScriptError(line: line, kind: .runtime, message: L("“game” has no “{}”.", name))
        }
    }

    private func setGameMember(_ name: String, _ value: ScriptValue, line: Int) throws {
        switch name {
        case "respawn_time":
            settings.respawnTime = Swift.min(try number(value, name, line), 600)
        case "friendly_fire":
            settings.friendlyFire = value.isTruthy
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("“game.{}” cannot be set.", name))
        }
    }

    // MARK: Helpers for the API

    private func method(_ name: String, _ body: @escaping ([ScriptValue], Int) throws -> ScriptValue) -> ScriptValue {
        .native(ScriptNative(name, body))
    }

    private func number(_ value: ScriptValue, _ what: String, _ line: Int) throws -> Double {
        guard case let .number(number) = value, number.isFinite else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("“{}” needs a number here, not {}.", what, value.typeName == "nil" ? "nil" : value.displayText))
        }
        return number
    }

    private func optionalNumber(_ arguments: [ScriptValue], _ index: Int, default fallback: Double, line: Int) throws -> Double {
        guard index < arguments.count else { return fallback }
        if case .null = arguments[index] { return fallback }
        return try number(arguments[index], "number", line)
    }

    private func shortText(_ value: ScriptValue, line: Int) throws -> String {
        String(value.displayText.prefix(HUDElement.Limits.maximumTextLength))
    }

    private func soundCue(_ value: ScriptValue, line: Int) throws -> SoundCue {
        guard let cue = SoundCue.named(value.displayText) else {
            throw ScriptError(line: line, kind: .runtime, message: L("There is no sound called “{}”. The sounds are: {}.",
                                                                     value.displayText,
                                                                     SoundCue.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        return cue
    }

    private func positionValue(_ position: Vec3) -> ScriptValue {
        let map = ScriptMap()
        map["x"] = .number(Self.rounded(position.x))
        map["y"] = .number(Self.rounded(position.y))
        map["z"] = .number(Self.rounded(position.z))
        return .map(map)
    }

    /// Positions to the centimetre, so `print(p.position)` is readable.
    private static func rounded(_ value: Float) -> Double {
        (Double(value) * 100).rounded() / 100
    }

    /// Where a player, a block or a `{x, y, z}` map is. For a block used as
    /// a teleport target, the point just above its top face.
    private func position(of value: ScriptValue, line: Int, standingOn: Bool = false) throws -> Vec3 {
        switch value {
        case let .object(object):
            if let state = playerState(object) {
                return machine.player(state.peer)?.position ?? .zero
            }
            if let id = blockID(object) {
                guard standingOn else { return world.worldPosition(of: id) }
                if let bounds = world.worldBounds(of: id) {
                    let centre = world.worldPosition(of: id)
                    // A metre above the top face, as checkpoints do, so
                    // nobody lands inside the block.
                    return Vec3(centre.x, bounds.max.y + 1, centre.z)
                }
                return world.worldPosition(of: id)
            }
        case let .map(map):
            if case let .number(x) = map["x"] ?? .null,
               case let .number(y) = map["y"] ?? .null,
               case let .number(z) = map["z"] ?? .null,
               x.isFinite, y.isFinite, z.isFinite {
                return Vec3(Float(x), Float(y), Float(z))
            }
        default:
            break
        }
        throw ScriptError(line: line, kind: .runtime,
                          message: L("That needs a player, a block or a position like {x: 0, y: 5, z: 0}, not {}.", value.typeName))
    }

    private func color(_ value: ScriptValue, line: Int) throws -> ColorRGBA {
        guard let color = ScriptColor.parse(value.displayText) else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("“{}” is not a colour. Try “red”, “blue” or “#FF8800”.", value.displayText))
        }
        return color
    }

    private func addTimer(_ arguments: [ScriptValue], repeating: Bool, line: Int) throws -> ScriptValue {
        let name = repeating ? "every" : "after"
        guard arguments.count >= 2 else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", name, 2))
        }
        var seconds = try number(arguments[0], name, line)
        switch arguments[1] {
        case .function, .native: break
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a function to run, like func() … end.", name))
        }
        guard timers.count < Limits.maximumTimers else {
            throw ScriptError(line: line, kind: .limit,
                              message: L("Too many timers at once (the limit is {}). Is “{}” inside “on tick”?",
                                         Limits.maximumTimers, name))
        }
        if repeating { seconds = Swift.max(seconds, Limits.minimumRepeatInterval) }
        seconds = Swift.max(seconds, 0)
        let id = nextTimerID
        nextTimerID += 1
        timers.append(ScriptTimer(id: id, due: clock + seconds, interval: repeating ? seconds : nil,
                                  callback: arguments[1], line: line))
        return .number(Double(id))
    }

    private func defineWeapon(_ arguments: [ScriptValue], line: Int) throws -> ScriptValue {
        let name = (arguments.first ?? .null).displayText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw ScriptError(line: line, kind: .runtime, message: L("A weapon needs a name."))
        }
        let key = name.lowercased()
        guard weapons[key] != nil || weapons.count < WeaponSpec.presets.count + Limits.maximumCustomWeapons else {
            throw ScriptError(line: line, kind: .limit, message: L("Too many weapons (the limit is {}).", Limits.maximumCustomWeapons))
        }
        // Starts from the preset of the same model, so `weapon("sniper",
        // {model: "rifle", damage: 90})` only has to say what is different.
        var options = ScriptMap()
        if arguments.count > 1, case let .map(map) = arguments[1] { options = map }
        let modelName = options["model"].map(\.displayText)?.lowercased() ?? weapons[key]?.model ?? "blaster"
        var spec = weapons[key] ?? WeaponSpec.presets[modelName] ?? WeaponSpec(name: name)
        spec.name = name
        spec.model = WeaponSpec.presets[modelName] != nil ? modelName : "blaster"

        for option in options.keys {
            let value = options[option] ?? .null
            switch option {
            case "damage": spec.damage = try number(value, "damage", line)
            case "rate": spec.fireRate = try number(value, "rate", line)
            case "range": spec.range = Float(try number(value, "range", line))
            case "ammo": spec.magazine = Int(try number(value, "ammo", line))
            case "reload": spec.reloadTime = try number(value, "reload", line)
            case "spread": spec.spread = Float(try number(value, "spread", line))
            case "model": break
            default:
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("A weapon has no “{}”. It can have: {}.", option,
                                             "damage, rate, range, ammo, reload, spread, model"))
            }
        }
        weapons[key] = spec.clamped
        return .string(name)
    }

    private func weaponNamed(_ value: ScriptValue, line: Int) throws -> WeaponSpec {
        let name = value.displayText
        guard let weapon = weapons[name.lowercased()] else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("There is no weapon called “{}”. The weapons are: {}.", name,
                                         weapons.keys.sorted().joined(separator: ", ")))
        }
        return weapon
    }

    // MARK: Screen GUI

    fileprivate enum HUDKind { case text, bar, button }

    private func hudElement(_ kind: HUDKind, _ arguments: [ScriptValue], line: Int) throws -> HUDElement {
        let id = (arguments.first ?? .null).displayText
        guard !id.isEmpty, id.count <= HUDElement.Limits.maximumIDLength else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("A screen item needs a short name first, like hud_text(\"score\", …)."))
        }

        let elementKind: HUDElement.Kind
        let optionsIndex: Int
        switch kind {
        case .text:
            elementKind = .text(try shortText(arguments.count > 1 ? arguments[1] : .null, line: line))
            optionsIndex = 2
        case .button:
            elementKind = .button(try shortText(arguments.count > 1 ? arguments[1] : .string(id), line: line))
            optionsIndex = 2
        case .bar:
            let value = try number(arguments.count > 1 ? arguments[1] : .null, "hud_bar", line)
            let maximum = try optionalNumber(arguments, 2, default: 100, line: line)
            guard maximum > 0 else {
                throw ScriptError(line: line, kind: .runtime, message: L("A bar’s maximum has to be more than 0."))
            }
            elementKind = .bar(value: Swift.min(Swift.max(value, 0), maximum), maximum: maximum)
            optionsIndex = 3
        }

        var element = HUDElement(id: id, kind: elementKind, anchor: kind == .button ? .right : .top)
        if optionsIndex < arguments.count, case let .map(options) = arguments[optionsIndex] {
            for key in options.keys {
                let value = options[key] ?? .null
                switch key {
                case "at":
                    guard let anchor = HUDElement.Anchor(rawValue: value.displayText.lowercased()) else {
                        throw ScriptError(line: line, kind: .runtime,
                                          message: L("“at” is one of: {}.", HUDElement.Anchor.allCases.map(\.rawValue).joined(separator: ", ")))
                    }
                    element.anchor = anchor
                case "color":
                    element.color = try color(value, line: line)
                case "size":
                    guard let size = HUDElement.Size(rawValue: value.displayText.lowercased()) else {
                        throw ScriptError(line: line, kind: .runtime, message: L("“size” is “small”, “medium” or “large”."))
                    }
                    element.size = size
                default:
                    throw ScriptError(line: line, kind: .runtime,
                                      message: L("A screen item has no “{}”. It can have: {}.", key, "at, color, size"))
                }
            }
        }
        return element
    }

    /// Shows an element to one player, or to everyone when `state` is nil.
    private func showHUD(_ element: HUDElement, to state: PlayerState?, line: Int) throws -> ScriptValue {
        let limit = HUDElement.Limits.maximumElements
        if let state {
            let isNew = state.hud[element.id] == nil && globalHUD[element.id] == nil
            if isNew, state.hud.count + globalHUD.count >= limit {
                throw ScriptError(line: line, kind: .limit, message: L("Too many things on the screen (the limit is {}).", limit))
            }
            state.hud[element.id] = element
            pending.append(personal(state.peer, .script(.hud(element))))
        } else {
            if globalHUD[element.id] == nil {
                let busiest = states.values.map(\.hud.count).max() ?? 0
                guard globalHUD.count + busiest < limit else {
                    throw ScriptError(line: line, kind: .limit, message: L("Too many things on the screen (the limit is {}).", limit))
                }
                globalHUDOrder.append(element.id)
            }
            globalHUD[element.id] = element
            pending.append(broadcast(.script(.hud(element))))
        }
        return .string(element.id)
    }

    private func removeHUD(_ id: String, from state: PlayerState?) {
        if let state {
            state.hud[id] = nil
            pending.append(personal(state.peer, .script(.removeHUD(id: id))))
        } else {
            globalHUD[id] = nil
            globalHUDOrder.removeAll { $0 == id }
            pending.append(broadcast(.script(.removeHUD(id: id))))
        }
    }

    private func clearHUD(for state: PlayerState?) {
        if let state {
            state.hud.removeAll()
            // Their own items only. The client clears the lot, so what
            // everyone sees is put back straight after.
            pending.append(personal(state.peer, .script(.clearHUD)))
            for id in globalHUDOrder {
                if let element = globalHUD[id] { pending.append(personal(state.peer, .script(.hud(element)))) }
            }
        } else {
            globalHUD.removeAll()
            globalHUDOrder.removeAll()
            for state in states.values { state.hud.removeAll() }
            pending.append(broadcast(.script(.clearHUD)))
        }
    }
}

// MARK: - Colours by name

/// Colours a script can name. English and Japanese, because the people
/// writing these scripts are children in both.
public enum ScriptColor {
    public static let named: [String: String] = [
        "red": "#EF4444", "orange": "#F97316", "yellow": "#FACC15", "green": "#22C55E",
        "blue": "#3B82F6", "cyan": "#22D3EE", "purple": "#A855F7", "pink": "#EC4899",
        "white": "#FFFFFF", "black": "#111111", "gray": "#9CA3AF", "grey": "#9CA3AF", "brown": "#92400E",
        "赤": "#EF4444", "オレンジ": "#F97316", "黄": "#FACC15", "黄色": "#FACC15", "緑": "#22C55E",
        "青": "#3B82F6", "水色": "#22D3EE", "紫": "#A855F7", "ピンク": "#EC4899",
        "白": "#FFFFFF", "黒": "#111111", "灰色": "#9CA3AF", "茶色": "#92400E"
    ]

    public static func parse(_ text: String) -> ColorRGBA? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = named[key.lowercased()] ?? named[key] { return ColorRGBA(hex: hex) }
        guard key.hasPrefix("#") else { return nil }
        return ColorRGBA(hex: key)
    }
}
