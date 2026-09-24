import Foundation

/// Everything a `.absc` script can call and read: the globals, and the members
/// of players, NPCs, blocks, the world, the game and screen items.
///
/// The rule for what belongs here is "could a game need it?", not "is it
/// small?". A script should be able to build a shooter, a shop menu, a
/// racing timer, an obstacle course that rebuilds itself or a zombie wave
/// without asking for a new feature first.
extension GameRuntime: ScriptObjectResolver {

    // MARK: Names, for Studio's reference and the tests that keep it complete

    public static let gameAPINames: [String] = [
        "game", "world", "players", "npcs", "find_player", "block", "blocks", "create_block", "create_npc",
        "distance", "raycast", "time", "after", "every", "cancel",
        "announce", "sound", "chat", "fade", "shake", "end_round", "restart_round", "weapon",
        "ui_text", "ui_button", "ui_panel", "ui_image", "ui_bar", "ui_input", "ui_set", "ui_remove", "ui_clear"
    ]

    /// Members every character has, player or NPC.
    public static let characterMemberNames: [String] = [
        "name", "id", "is_npc", "health", "max_health", "alive", "score", "team",
        "position", "x", "y", "z", "yaw", "look", "velocity",
        "weapon", "ammo", "speed", "jump", "gravity", "frozen",
        "color", "head_color", "leg_color", "size", "hat", "ride", "ride_color", "visible",
        "give", "take", "reload", "teleport", "damage", "heal", "kill", "respawn", "launch", "look_at"
    ]

    /// Members only a person has: their screen and camera.
    public static let playerOnlyMemberNames: [String] = [
        "camera", "camera_distance", "fov", "controls", "default_ui",
        "camera_look", "camera_reset", "message", "sound", "chat", "fade", "shake",
        "ui_text", "ui_button", "ui_panel", "ui_image", "ui_bar", "ui_input", "ui_set", "ui_remove", "ui_clear"
    ]

    /// Members only an NPC has: being told where to go.
    public static let npcOnlyMemberNames: [String] = [
        "move_to", "follow", "stop", "jump_now", "shoot", "say", "destroy"
    ]

    public static let blockMemberNames: [String] = [
        "name", "id", "position", "x", "y", "z", "size", "rotation", "color", "material", "shape",
        "visible", "solid", "tags", "opacity", "behavior", "move", "move_to", "rotate", "destroy", "clone"
    ]

    public static let worldMemberNames: [String] = [
        "gravity", "sky", "sky_top", "sky_bottom", "light", "sun", "sun_yaw", "ground", "ground_color", "fall_height"
    ]

    public static let uiOptionNames: [String] = [
        "at", "x", "y", "pivot", "dx", "dy", "w", "h", "color", "bg", "size", "bold", "radius",
        "opacity", "visible", "layer", "parent", "text", "value", "max"
    ]

    // MARK: Globals

    func installGameAPI(on interpreter: ScriptInterpreter) {
        interpreter.defineValue("game", .object(ScriptObject(kind: "game", id: "game", displayName: "game")))
        interpreter.defineValue("world", .object(ScriptObject(kind: "world", id: "world", displayName: "world")))

        interpreter.define("players") { [unowned self] _, _ in
            .list(ScriptList(self.orderedStates.filter { !$0.isNPC }.map { self.object(for: $0) }))
        }
        interpreter.define("npcs") { [unowned self] _, _ in
            .list(ScriptList(self.orderedStates.filter(\.isNPC).map { self.object(for: $0) }))
        }
        interpreter.define("find_player") { [unowned self] arguments, _ in
            let name = (arguments.first ?? .null).displayText
            let match = self.orderedStates.first { !$0.isNPC && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return match.map { self.object(for: $0) } ?? .null
        }

        interpreter.define("block") { [unowned self] arguments, _ in
            let name = (arguments.first ?? .null).displayText
            let match = self.world.blocks.first { $0.name == name }
                ?? self.world.blocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return match.map { self.blockObject($0.id) } ?? .null
        }
        interpreter.define("blocks") { [unowned self] arguments, _ in
            let found = arguments.isEmpty || (arguments.first?.isNull ?? true)
                ? self.world.blocks
                : self.world.blocks(taggedWith: (arguments.first ?? .null).displayText)
            return .list(ScriptList(found.map { self.blockObject($0.id) }))
        }
        interpreter.define("create_block") { [unowned self] arguments, line in
            try self.createBlock(arguments.first ?? .null, line: line)
        }
        interpreter.define("create_npc") { [unowned self] arguments, line in
            try self.createNPC(arguments.first ?? .null, line: line)
        }

        interpreter.define("distance") { [unowned self] arguments, line in
            guard arguments.count >= 2 else {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "distance", 2))
            }
            let a = try self.point(arguments[0], line: line)
            let b = try self.point(arguments[1], line: line)
            return .number(Double(a.distance(to: b)))
        }
        interpreter.define("raycast") { [unowned self] arguments, line in
            try self.raycast(arguments, line: line)
        }
        interpreter.define("time") { [unowned self] _, _ in
            .number(self.clock - self.roundStartedAt)
        }

        // Timers

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

        // Everyone

        interpreter.define("announce") { [unowned self] arguments, line in
            let text = self.shortText(arguments.first ?? .null)
            let seconds = try self.optionalNumber(arguments, 1, default: 3, line: line)
            self.pending.append(self.broadcast(.announce(message: text, duration: Swift.min(Swift.max(seconds, 0.3), 120))))
            return .null
        }
        interpreter.define("sound") { [unowned self] arguments, line in
            let cue = try self.soundCue(arguments.first ?? .null, line: line)
            self.pending.append(self.broadcast(.playSound(name: cue.rawValue)))
            return .null
        }
        interpreter.define("chat") { [unowned self] arguments, _ in
            self.pending.append(self.broadcast(.script(.chat(self.shortText(arguments.first ?? .null)))))
            return .null
        }
        interpreter.define("fade") { [unowned self] arguments, line in
            let effect = try self.fadeEffect(arguments, line: line)
            self.pending.append(self.broadcast(.script(effect)))
            return .null
        }
        interpreter.define("shake") { [unowned self] arguments, line in
            let effect = try self.shakeEffect(arguments, line: line)
            self.pending.append(self.broadcast(.script(effect)))
            return .null
        }
        interpreter.define("end_round") { [unowned self] arguments, _ in
            let text = arguments.isEmpty || (arguments.first?.isNull ?? true)
                ? L("Round over") : self.shortText(arguments[0])
            self.pending.append(self.broadcast(.endRound(message: text)))
            self.machine.endRound()
            return .null
        }
        interpreter.define("restart_round") { [unowned self] _, _ in
            // At the next tick, not now: this call is inside a handler of the
            // very script a restart replaces.
            self.pendingRestart = true
            return .null
        }
        interpreter.define("weapon") { [unowned self] arguments, line in
            try self.defineWeapon(arguments, line: line)
        }

        // Screen, for everyone

        for kind in UIElement.Kind.allCases {
            interpreter.define("ui_\(kind.rawValue)") { [unowned self] arguments, line in
                try self.createUI(kind, arguments, owner: nil, line: line)
            }
        }
        interpreter.define("ui_set") { [unowned self] arguments, line in
            try self.setUI(arguments, owner: nil, line: line)
        }
        interpreter.define("ui_remove") { [unowned self] arguments, _ in
            self.removeUI(self.uiID(arguments.first ?? .null), owner: nil)
            return .null
        }
        interpreter.define("ui_clear") { [unowned self] _, _ in
            self.clearUI(owner: nil)
            return .null
        }
    }

    // MARK: Members

    public func member(of object: ScriptObject, named name: String, line: Int) throws -> ScriptValue {
        switch object.kind {
        case "player", "npc": return try characterMember(object, name, line: line)
        case "block": return try blockMember(object, name, line: line)
        case "game": return try gameMember(name, line: line)
        case "world": return try worldMember(name, line: line)
        case "ui": return try uiMember(object, name, line: line)
        default: return .null
        }
    }

    public func setMember(of object: ScriptObject, named name: String, to value: ScriptValue, line: Int) throws {
        switch object.kind {
        case "player", "npc": try setCharacterMember(object, name, value, line: line)
        case "block": try setBlockMember(object, name, value, line: line)
        case "game": try setGameMember(name, value, line: line)
        case "world": try setWorldMember(name, value, line: line)
        case "ui": try setUIMember(object, name, value, line: line)
        default: throw ScriptError(line: line, kind: .runtime, message: L("“{}” cannot be changed here.", name))
        }
    }

    // MARK: Characters

    private func characterMember(_ object: ScriptObject, _ name: String, line: Int) throws -> ScriptValue {
        // Someone who has left still has a name, so a goodbye message works.
        guard let state = character(object) else {
            switch name {
            case "name": return .string(object.displayName)
            case "alive": return .bool(false)
            default: return .null
            }
        }
        let body = snapshot(of: state)
        let position = body?.position ?? .zero

        switch name {
        case "name": return .string(state.name)
        case "id": return .string(state.peer.description)
        case "is_npc": return .bool(state.isNPC)
        case "health": return .number(state.health)
        case "max_health": return .number(state.maxHealth)
        case "alive": return .bool(state.isAlive)
        case "score": return .number(Double(state.isNPC ? state.npcScore : body?.score ?? 0))
        case "team": return state.team.isEmpty ? .null : .string(state.team)
        case "position": return vectorValue(position)
        case "x": return .number(Self.rounded(position.x))
        case "y": return .number(Self.rounded(position.y))
        case "z": return .number(Self.rounded(position.z))
        case "yaw": return .number(Double(body?.yawDegrees ?? 0))
        case "look": return ScriptVector(Quat.yaw(degrees: -(body?.yawDegrees ?? 0)).act(Vec3(0, 0, -1))).value
        case "velocity": return ScriptVector(body?.velocity ?? .zero).value
        case "weapon": return state.armed.map { .string($0.weapon.name) } ?? .null
        case "ammo": return state.armed.map { .number(Double($0.ammo)) } ?? .null
        case "speed": return .number(Double(state.movement.speed))
        case "jump": return .number(Double(state.movement.jump))
        case "gravity": return .number(Double(state.movement.gravity))
        case "frozen": return .bool(state.movement.frozen)
        case "color": return .string(state.profile.bodyColor.hexString)
        case "head_color": return .string(state.profile.headColor.hexString)
        case "leg_color": return .string(state.profile.accentColor.hexString)
        case "size": return .number(Double(state.profile.height))
        case "hat": return .string(state.profile.hat.rawValue)
        case "ride": return .string(state.profile.ride.rawValue)
        case "ride_color": return .string(state.profile.rideColor.hexString)
        case "visible": return .bool(!state.isHidden)
        case "camera": return .string(state.camera.mode.rawValue)
        case "camera_distance": return .number(Double(state.camera.distance))
        case "fov": return .number(Double(state.camera.fieldOfView))
        case "controls": return .bool(state.showsControls)
        case "default_ui": return .bool(state.showsDefaultUI)

        case "give":
            return method(name) { [unowned self] arguments, line in
                let weapon = try self.weaponNamed(arguments.first ?? .null, line: line)
                state.armed = ArmedState(weapon: weapon)
                self.send(state, .script(.equip(weapon.clamped)))
                self.sendAmmo(state)
                // A player with a weapon is in a fight, so their health
                // shows from now on rather than after the first hit.
                self.sendHealth(state)
                return .null
            }
        case "take":
            return method(name) { [unowned self] _, _ in
                state.armed = nil
                self.send(state, .script(.equip(nil)))
                return .null
            }
        case "reload":
            return method(name) { [unowned self] _, _ in
                if state.armed?.startReload(at: self.clock) == true { self.sendAmmo(state) }
                return .null
            }
        case "teleport":
            return method(name) { [unowned self] arguments, line in
                self.teleport(state, to: try self.destination(arguments, line: line))
                return .null
            }
        case "damage":
            return method(name) { [unowned self] arguments, line in
                let amount = try self.number(arguments.first ?? .null, "damage", line)
                self.applyDamage(amount, to: state, from: self.characterArgument(arguments, 1))
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
                self.knockOut(state, by: self.characterArgument(arguments, 0))
                return .null
            }
        case "respawn":
            return method(name) { [unowned self] _, _ in
                self.respawn(state)
                return .null
            }
        case "launch":
            return method(name) { [unowned self] arguments, line in
                self.launch(state, try self.vectorArgument(arguments, line: line, what: "launch"))
                return .null
            }
        case "look_at":
            return method(name) { [unowned self] arguments, line in
                let target = try self.point(arguments.first ?? .null, line: line)
                let offset = target - position
                guard offset.x * offset.x + offset.z * offset.z > 1e-6 else { return .null }
                self.face(state, yaw: atan2(offset.x, -offset.z) * 180 / .pi)
                return .null
            }

        // A person's screen and camera
        case "camera_look":
            return method(name) { [unowned self] arguments, line in
                var camera = state.camera
                camera.mode = .fixed
                camera.position = try self.point(arguments.first ?? .null, line: line)
                camera.target = arguments.count > 1 && !arguments[1].isNull ? try self.point(arguments[1], line: line) : nil
                self.setCamera(state, camera)
                return .null
            }
        case "camera_reset":
            return method(name) { [unowned self] _, _ in
                self.setCamera(state, .standard)
                return .null
            }
        case "message":
            return method(name) { [unowned self] arguments, line in
                let text = self.shortText(arguments.first ?? .null)
                let seconds = try self.optionalNumber(arguments, 1, default: 3, line: line)
                self.send(state, .announce(message: text, duration: Swift.min(Swift.max(seconds, 0.3), 120)))
                return .null
            }
        case "sound":
            return method(name) { [unowned self] arguments, line in
                self.send(state, .playSound(name: try self.soundCue(arguments.first ?? .null, line: line).rawValue))
                return .null
            }
        case "chat":
            return method(name) { [unowned self] arguments, _ in
                self.send(state, .script(.chat(self.shortText(arguments.first ?? .null))))
                return .null
            }
        case "fade":
            return method(name) { [unowned self] arguments, line in
                self.send(state, .script(try self.fadeEffect(arguments, line: line)))
                return .null
            }
        case "shake":
            return method(name) { [unowned self] arguments, line in
                self.send(state, .script(try self.shakeEffect(arguments, line: line)))
                return .null
            }
        case "ui_text", "ui_button", "ui_panel", "ui_image", "ui_bar", "ui_input":
            let kind = UIElement.Kind(rawValue: String(name.dropFirst(3))) ?? .text
            return method(name) { [unowned self] arguments, line in
                try self.createUI(kind, arguments, owner: state, line: line)
            }
        case "ui_set":
            return method(name) { [unowned self] arguments, line in
                try self.setUI(arguments, owner: state, line: line)
            }
        case "ui_remove":
            return method(name) { [unowned self] arguments, _ in
                self.removeUI(self.uiID(arguments.first ?? .null), owner: state)
                return .null
            }
        case "ui_clear":
            return method(name) { [unowned self] _, _ in
                self.clearUI(owner: state)
                return .null
            }

        // Telling an NPC what to do
        case "move_to":
            return npcMethod(state, name) { [unowned self] arguments, line in
                state.goal = .point(try self.point(arguments.first ?? .null, line: line))
                return .null
            }
        case "follow":
            return npcMethod(state, name) { [unowned self] arguments, line in
                if let target = self.characterArgument(arguments, 0) {
                    state.goal = .character(target.peer)
                } else {
                    state.goal = .point(try self.point(arguments.first ?? .null, line: line))
                }
                return .null
            }
        case "stop":
            return npcMethod(state, name) { _, _ in
                state.goal = .none
                return .null
            }
        case "jump_now":
            return npcMethod(state, name) { _, _ in
                state.wantsJump = true
                return .null
            }
        case "shoot":
            return npcMethod(state, name) { [unowned self] arguments, line in
                var target = try self.point(arguments.first ?? .null, line: line)
                if self.characterArgument(arguments, 0) != nil { target.y += 1.0 }
                let eyes = position + Vec3(0, PlayerHitBody.eyeHeight * state.profile.height, 0)
                self.fire(state, origin: eyes, direction: target - eyes)
                return .null
            }
        case "say":
            return npcMethod(state, name) { [unowned self] arguments, _ in
                let text = self.shortText(arguments.first ?? .null)
                self.pending.append(self.broadcast(.script(.say(speaker: state.peer, name: state.name, text: text))))
                return .null
            }
        case "destroy":
            return npcMethod(state, name) { [unowned self] _, _ in
                self.removeNPC(state)
                return .null
            }

        default:
            return state.custom[name] ?? .null
        }
    }

    private func setCharacterMember(_ object: ScriptObject, _ name: String, _ value: ScriptValue, line: Int) throws {
        guard let state = character(object) else { return }   // they left; nothing to change

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
            guard Swift.abs(score) < 1_000_000_000_000 else {
                throw ScriptError(line: line, kind: .runtime, message: L("That number is too big."))
            }
            setScore(state, to: Int(score.rounded()))
        case "team":
            state.team = value.isNull ? "" : String(value.displayText.prefix(32))
        case "position":
            teleport(state, to: try point(value, line: line))
        case "yaw":
            face(state, yaw: Float(try number(value, name, line)))
        case "velocity":
            launch(state, try vector(value, line: line))
        case "speed", "jump", "gravity":
            let multiplier = Float(Swift.min(Swift.max(try number(value, name, line), 0), Double(Limits.maximumMovementMultiplier)))
            switch name {
            case "speed": state.movement.speed = multiplier
            case "jump": state.movement.jump = multiplier
            default: state.movement.gravity = multiplier
            }
            if state.isAlive { send(state, .script(.movement(state.movement))) }
        case "frozen":
            state.movement.frozen = value.isTruthy
            if state.isAlive { send(state, .script(.movement(state.movement))) }
        case "color":
            let color = try self.color(value, line: line)
            updateProfile(state) { $0.bodyColor = color }
        case "head_color":
            let color = try self.color(value, line: line)
            updateProfile(state) { $0.headColor = color }
        case "leg_color":
            let color = try self.color(value, line: line)
            updateProfile(state) { $0.accentColor = color }
        case "size":
            let size = Float(Swift.min(Swift.max(try number(value, name, line), Double(Limits.minimumSize)), Double(Limits.maximumSize)))
            updateProfile(state) { $0.height = size }
        case "hat":
            let text = value.isNull ? "none" : value.displayText.lowercased()
            guard let hat = AvatarProfile.HatStyle(rawValue: text) else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“hat” is one of: {}.", AvatarProfile.HatStyle.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            updateProfile(state) { $0.hat = hat }
        case "ride":
            let text = value.isNull ? "none" : value.displayText.lowercased()
            guard let ride = AvatarProfile.Ride(rawValue: text) else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“ride” is one of: {}.", AvatarProfile.Ride.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            updateProfile(state) { $0.ride = ride }
        case "ride_color":
            let color = try self.color(value, line: line)
            updateProfile(state) { $0.rideColor = color }
        case "name":
            let text = String(value.displayText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            guard !text.isEmpty else { return }
            updateProfile(state) { $0.displayName = text }
        case "visible":
            let hidden = !value.isTruthy
            if hidden != state.isHidden {
                state.isHidden = hidden
                rosterChanged = true
            }
        case "camera":
            let text = value.displayText.lowercased()
            let aliases: [String: CameraSettings.Mode] = ["first_person": .firstPerson, "third_person": .thirdPerson, "top_down": .topDown]
            guard let mode = CameraSettings.Mode(rawValue: text) ?? aliases[text] else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“camera” is one of: {}.", CameraSettings.Mode.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            var camera = state.camera
            camera.mode = mode
            setCamera(state, camera)
        case "camera_distance":
            var camera = state.camera
            camera.distance = Float(Swift.min(Swift.max(try number(value, name, line), 0.5), 300))
            setCamera(state, camera)
        case "fov":
            var camera = state.camera
            camera.fieldOfView = Float(Swift.min(Swift.max(try number(value, name, line), 10), 150))
            setCamera(state, camera)
        case "controls":
            state.showsControls = value.isTruthy
            send(state, .script(.interface(controls: state.showsControls, defaultUI: state.showsDefaultUI)))
        case "default_ui":
            state.showsDefaultUI = value.isTruthy
            send(state, .script(.interface(controls: state.showsControls, defaultUI: state.showsDefaultUI)))
        case "ammo":
            guard var armed = state.armed else { return }
            armed.ammo = Swift.min(Swift.max(Int(try number(value, name, line)), 0), armed.weapon.magazine)
            armed.reloadEnds = nil
            state.armed = armed
            sendAmmo(state)
        case "id", "is_npc", "alive", "x", "y", "z", "look", "weapon":
            throw ScriptError(line: line, kind: .runtime, message: L("A character’s “{}” cannot be set directly.", name))
        default:
            if Self.characterMemberNames.contains(name) || Self.playerOnlyMemberNames.contains(name)
                || Self.npcOnlyMemberNames.contains(name) {
                throw ScriptError(line: line, kind: .runtime, message: L("“{}” is a function. Call it with ().", name))
            }
            if value.isNull {
                state.custom[name] = nil
            } else {
                guard state.custom[name] != nil || state.custom.count < Limits.maximumCustomValues else {
                    throw ScriptError(line: line, kind: .limit, message: L("Too many values stored on one character."))
                }
                state.custom[name] = value
            }
        }
    }

    private func npcMethod(_ state: PlayerState, _ name: String,
                           _ body: @escaping ([ScriptValue], Int) throws -> ScriptValue) -> ScriptValue {
        method(name) { arguments, line in
            guard state.isNPC else {
                throw ScriptError(line: line, kind: .runtime, message: L("Only an NPC can “{}”.", name))
            }
            return try body(arguments, line)
        }
    }

    private func setCamera(_ state: PlayerState, _ camera: CameraSettings) {
        state.camera = camera
        send(state, .script(.camera(camera)))
    }

    private func launch(_ state: PlayerState, _ velocity: Vec3) {
        if state.isNPC {
            state.body?.velocity = velocity
            state.body?.isGrounded = false
        } else {
            send(state, .script(.launch(velocity)))
        }
    }

    private func face(_ state: PlayerState, yaw: Float) {
        guard yaw.isFinite else { return }
        if state.isNPC {
            state.body?.yawDegrees = yaw
            state.needsTransformSend = true
        } else {
            send(state, .script(.face(yawDegrees: yaw)))
        }
    }

    private func createNPC(_ value: ScriptValue, line: Int) throws -> ScriptValue {
        guard states.values.filter(\.isNPC).count < Limits.maximumNPCs else {
            throw ScriptError(line: line, kind: .limit, message: L("Too many NPCs (the limit is {}).", Limits.maximumNPCs))
        }
        let options = try optionsMap(value, line: line)
        var profile = AvatarProfile.default
        profile.displayName = options["name"].map { String($0.displayText.prefix(24)) } ?? "NPC"
        if let color = options["color"] { profile.bodyColor = try self.color(color, line: line) }
        if let color = options["head_color"] { profile.headColor = try self.color(color, line: line) }
        if let color = options["leg_color"] { profile.accentColor = try self.color(color, line: line) }
        if let size = options["size"] {
            profile.height = Float(Swift.min(Swift.max(try number(size, "size", line), Double(Limits.minimumSize)), Double(Limits.maximumSize)))
        }
        if let hat = options["hat"], let style = AvatarProfile.HatStyle(rawValue: hat.displayText.lowercased()) {
            profile.hat = style
        }
        if let ride = options["ride"], let kind = AvatarProfile.Ride(rawValue: ride.displayText.lowercased()) {
            profile.ride = kind
        }
        if let color = options["ride_color"] { profile.rideColor = try self.color(color, line: line) }
        let start = try optionalPoint(options, line: line) ?? world.spawnPosition(forPlayerIndex: 0)

        let peer = PeerID()
        let state = PlayerState(peer: peer, joinOrder: joinCounter, name: profile.displayName, profile: profile, isNPC: true)
        joinCounter += 1
        state.body = PlayerSnapshot(peerID: peer, profile: profile, position: start, isNPC: true)
        state.home = start
        if let health = options["health"] {
            state.maxHealth = Swift.min(Swift.max(try number(health, "health", line), 1), Limits.maximumHealth)
            state.health = state.maxHealth
        }
        if let speed = options["speed"] {
            state.movement.speed = Float(Swift.min(Swift.max(try number(speed, "speed", line), 0), Double(Limits.maximumMovementMultiplier)))
        }
        if let team = options["team"], !team.isNull { state.team = String(team.displayText.prefix(32)) }
        states[peer] = state
        rosterChanged = true
        return object(for: state)
    }

    // MARK: Blocks

    private func blockMember(_ object: ScriptObject, _ name: String, line: Int) throws -> ScriptValue {
        // Through the index: a plain lookup searched every block, and a
        // script looping over its blocks paid that for each one.
        let index = worldIndex
        guard let id = blockID(object), let entry = index.entry(for: id) else {
            if name == "name" { return .string(object.displayName) }
            return .null
        }
        let block = world.blocks[entry.order]
        let position = entry.position
        switch name {
        case "name": return .string(block.name)
        case "id": return .string(String(id.uuidString.prefix(8)))
        case "position": return vectorValue(position)
        case "x": return .number(Self.rounded(position.x))
        case "y": return .number(Self.rounded(position.y))
        case "z": return .number(Self.rounded(position.z))
        case "size": return vectorValue(block.scale)
        case "rotation": return vectorValue(block.rotationDegrees)
        case "color": return .string(block.color.hexString)
        case "material": return .string(block.material.rawValue)
        case "shape": return .string(block.shape.rawValue)
        case "visible": return .bool(block.isVisible)
        case "solid": return .bool(block.hasCollision)
        case "tags": return .list(ScriptList(block.tags.map { .string($0) }))
        case "opacity": return .number(Double(block.color.a))
        case "behavior": return .string(block.behavior.rawValue)
        case "move", "move_to":
            return method(name) { [unowned self] arguments, line in
                let seconds: Double
                let offset: Vec3
                if name == "move" {
                    offset = try self.vectorArgument(arguments, line: line, what: "move")
                    seconds = try self.optionalNumber(arguments, ScriptVector(arguments.first ?? .null) == nil ? 3 : 1, default: 0, line: line)
                } else {
                    offset = try self.point(arguments.first ?? .null, line: line) - self.world.worldPosition(of: id)
                    seconds = try self.optionalNumber(arguments, 1, default: 0, line: line)
                }
                self.moveBlock(id, by: offset, over: Swift.min(Swift.max(seconds, 0), 600))
                return .null
            }
        case "rotate":
            return method(name) { [unowned self] arguments, line in
                let turn = try self.vectorArgument(arguments, line: line, what: "rotate")
                try self.changeBlock(id) { $0.rotationDegrees = $0.rotationDegrees + turn }
                return .null
            }
        case "destroy":
            return method(name) { [unowned self] _, _ in
                if self.world.block(id: id) != nil { self.queue(.remove(blockID: id)) }
                return .null
            }
        case "clone":
            return method(name) { [unowned self] _, line in
                guard var copy = self.world.block(id: id) else { return .null }
                try self.checkBlockLimit(line: line)
                copy.id = UUID()
                self.queue(.insert(copy))
                return self.blockObject(copy.id)
            }
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A block has no “{}”.", name))
        }
    }

    private func setBlockMember(_ object: ScriptObject, _ name: String, _ value: ScriptValue, line: Int) throws {
        guard let id = blockID(object) else { return }
        try changeBlock(id) { block in
            try self.applyBlockOption(name, value, to: &block, id: id, line: line)
        }
    }

    /// One block property, shared by `b.color = …` and `create_block({color: …})`.
    private func applyBlockOption(_ name: String, _ value: ScriptValue, to block: inout BlockData, id: UUID?, line: Int) throws {
        switch name {
        case "name":
            block.name = String(value.displayText.prefix(60))
        case "position":
            let target = try point(value, line: line)
            // A block inside another is placed relative to it; asking for a
            // world position means taking the parent's offset back off.
            let parentOffset = id.map { world.worldPosition(of: $0) - block.position } ?? .zero
            block.position = target - parentOffset
        case "x", "y", "z":
            let n = Float(try number(value, name, line))
            if name == "x" { block.position.x = n } else if name == "y" { block.position.y = n } else { block.position.z = n }
        case "size":
            if case let .number(n) = value {
                block.scale = Vec3(repeating: Float(Swift.min(Swift.max(n, 0.01), 2_000)))
            } else {
                let size = try vector(value, line: line)
                block.scale = Vec3(Swift.min(Swift.max(size.x, 0.01), 2_000), Swift.min(Swift.max(size.y, 0.01), 2_000),
                                   Swift.min(Swift.max(size.z, 0.01), 2_000))
            }
        case "rotation":
            block.rotationDegrees = try vector(value, line: line)
        case "color":
            let alpha = block.color.a
            block.color = try color(value, line: line).withAlpha(alpha)
        case "opacity":
            block.color = block.color.withAlpha(Float(Swift.min(Swift.max(try number(value, name, line), 0), 1)))
        case "material":
            guard let material = MaterialKind(rawValue: value.displayText.lowercased()) else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“material” is one of: {}.", MaterialKind.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            block.material = material
        case "shape":
            guard let shape = BlockShape(rawValue: value.displayText.lowercased()) else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“shape” is one of: {}.", BlockShape.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            block.shape = shape
        case "visible":
            block.isVisible = value.isTruthy
        case "solid":
            block.hasCollision = value.isTruthy
        case "anchored":
            block.isAnchored = value.isTruthy
        case "behavior":
            // What touching it does, and whether touching it is noticed at
            // all: only a block with a behaviour reports `on touch`, so a
            // script-made coin or door needs "trigger" (walk through it) or
            // another behaviour to be touchable.
            let text = value.isNull ? "none" : value.displayText.lowercased()
            guard let behavior = BlockBehavior(rawValue: text) else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“behavior” is one of: {}.", BlockBehavior.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            block.behavior = behavior
        case "tags":
            guard case let .list(list) = value else {
                throw ScriptError(line: line, kind: .runtime, message: L("“tags” needs a list, like [\"coin\"]."))
            }
            block.tags = list.items.prefix(32).map { String($0.displayText.prefix(40)) }
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A block’s “{}” cannot be set.", name))
        }
    }

    private func changeBlock(_ id: UUID, _ change: (inout BlockData) throws -> Void) throws {
        guard var block = world.block(id: id) else { return }
        try change(&block)
        guard block != world.block(id: id) else { return }
        queue(.update(block))
    }

    private func moveBlock(_ id: UUID, by offset: Vec3, over seconds: Double) {
        guard var block = world.block(id: id) else { return }
        block.position += offset
        guard seconds > 0 else {
            queue(.update(block))
            return
        }
        // Everyone's iPad animates the move; the map takes the end position
        // now for shots and collisions on the host, and everyone else's copy
        // gets it when the move has finished.
        machine.apply(.update(block))
        pending.append(broadcast(.move(blockID: id, offset: offset, duration: seconds)))
        deferredUpdates.append((due: clock + seconds, blockID: id))
    }

    private func checkBlockLimit(line: Int) throws {
        guard world.blocks.count < Limits.maximumBlocks else {
            throw ScriptError(line: line, kind: .limit, message: L("The world has too many blocks (the limit is {}).", Limits.maximumBlocks))
        }
    }

    private func createBlock(_ value: ScriptValue, line: Int) throws -> ScriptValue {
        try checkBlockLimit(line: line)
        let options = try optionsMap(value, line: line)
        var block = BlockData(name: "Block")
        block.position = Vec3(0, 1, 0)
        for key in options.keys {
            guard let option = options[key] else { continue }
            try applyBlockOption(key, option, to: &block, id: nil, line: line)
        }
        queue(.insert(block))
        return blockObject(block.id)
    }

    // MARK: World and game

    private func worldMember(_ name: String, line: Int) throws -> ScriptValue {
        let environment = world.environment
        switch name {
        case "gravity": return .number(Double(environment.gravity))
        case "sky", "sky_top": return .string(environment.skyTop.hexString)
        case "sky_bottom": return .string(environment.skyBottom.hexString)
        case "light": return .number(Double(environment.ambientIntensity))
        case "sun": return .number(Double(environment.sunPitchDegrees))
        case "sun_yaw": return .number(Double(environment.sunYawDegrees))
        case "ground": return .bool(environment.showGroundPlane)
        case "ground_color": return .string(environment.groundColor.hexString)
        case "fall_height": return .number(Double(environment.killPlaneHeight))
        default: throw ScriptError(line: line, kind: .runtime, message: L("“world” has no “{}”.", name))
        }
    }

    private func setWorldMember(_ name: String, _ value: ScriptValue, line: Int) throws {
        var environment = world.environment
        switch name {
        case "gravity": environment.gravity = Float(Swift.min(Swift.max(try number(value, name, line), -100), 0))
        case "sky":
            let color = try self.color(value, line: line)
            environment.skyTop = color
            environment.skyBottom = color
        case "sky_top": environment.skyTop = try color(value, line: line)
        case "sky_bottom": environment.skyBottom = try color(value, line: line)
        case "light": environment.ambientIntensity = Float(Swift.min(Swift.max(try number(value, name, line), 0), 3))
        case "sun": environment.sunPitchDegrees = Float(try number(value, name, line))
        case "sun_yaw": environment.sunYawDegrees = Float(try number(value, name, line))
        case "ground": environment.showGroundPlane = value.isTruthy
        case "ground_color": environment.groundColor = try color(value, line: line)
        case "fall_height": environment.killPlaneHeight = Float(Swift.min(Swift.max(try number(value, name, line), -10_000), 10_000))
        default: throw ScriptError(line: line, kind: .runtime, message: L("“world.{}” cannot be set.", name))
        }
        guard environment != world.environment else { return }
        queue(.environment(environment))
    }

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
        case "respawn_time": settings.respawnTime = Swift.min(try number(value, name, line), 3_600)
        case "friendly_fire": settings.friendlyFire = value.isTruthy
        default: throw ScriptError(line: line, kind: .runtime, message: L("“game.{}” cannot be set.", name))
        }
    }

    // MARK: Screen GUI

    /// `ui_text("score", "Score: 0", {at: "top_left", size: 24})` and friends.
    ///
    /// Calling one again with the same id updates that item, keeping every
    /// option not given — so `ui_text("score", "Score: " + s)` in `on tick`
    /// changes the words and leaves it where it was.
    private func createUI(_ kind: UIElement.Kind, _ arguments: [ScriptValue], owner: PlayerState?, line: Int) throws -> ScriptValue {
        let id = uiID(arguments.first ?? .null)
        guard !id.isEmpty, id.count <= UIElement.Limits.maximumIDLength else {
            throw ScriptError(line: line, kind: .runtime, message: L("A screen item needs a short name first, like ui_text(\"score\", …)."))
        }

        var element = existingUI(id, owner: owner) ?? defaultElement(id: id, kind: kind)
        element.kind = kind
        var optionsIndex = 1
        switch kind {
        case .panel:
            break
        case .text, .button, .image, .input:
            if arguments.count > 1, !isOptions(arguments[1]) {
                element.text = shortText(arguments[1])
                optionsIndex = 2
            }
        case .bar:
            if arguments.count > 1, !isOptions(arguments[1]) {
                element.value = try number(arguments[1], "ui_bar", line)
                optionsIndex = 2
                if arguments.count > 2, !isOptions(arguments[2]) {
                    let maximum = try number(arguments[2], "ui_bar", line)
                    guard maximum > 0 else {
                        throw ScriptError(line: line, kind: .runtime, message: L("A bar’s maximum has to be more than 0."))
                    }
                    element.maximum = maximum
                    optionsIndex = 3
                }
            }
        }
        if optionsIndex < arguments.count {
            try applyUIOptions(arguments[optionsIndex], to: &element, line: line)
        }
        try showUI(element, owner: owner, line: line)
        return uiHandle(id, owner: owner)
    }

    private func setUI(_ arguments: [ScriptValue], owner: PlayerState?, line: Int) throws -> ScriptValue {
        let id = uiID(arguments.first ?? .null)
        guard var element = existingUI(id, owner: owner) else {
            throw ScriptError(line: line, kind: .runtime, message: L("There is no screen item called “{}”.", id))
        }
        if arguments.count > 1 { try applyUIOptions(arguments[1], to: &element, line: line) }
        try showUI(element, owner: owner, line: line)
        return uiHandle(id, owner: owner)
    }

    private func defaultElement(id: String, kind: UIElement.Kind) -> UIElement {
        var element = UIElement(id: id, kind: kind)
        switch kind {
        case .panel:
            element.width = 320
            element.height = 220
            element.background = ColorRGBA(r: 0, g: 0, b: 0, a: 0.55)
            element.cornerRadius = 18
        case .text:
            element.color = .white
        case .button:
            element.color = .white
            element.background = ColorRGBA(hex: "#3B82F6")
            element.fontSize = 20
            element.bold = true
        case .image:
            element.text = "star.fill"
            element.color = .white
            element.fontSize = 36
        case .bar:
            element.width = 200
            element.height = 14
            element.color = ColorRGBA(hex: "#22D3EE")
            element.background = ColorRGBA(r: 0, g: 0, b: 0, a: 0.4)
            element.cornerRadius = 7
        case .input:
            element.width = 260
            element.color = .white
            element.background = ColorRGBA(r: 0, g: 0, b: 0, a: 0.5)
        }
        return element
    }

    private func isOptions(_ value: ScriptValue) -> Bool {
        if case .map = value, ScriptVector(value) == nil { return true }
        return false
    }

    func applyUIOptions(_ value: ScriptValue, to element: inout UIElement, line: Int) throws {
        let options = try optionsMap(value, line: line)
        for key in options.keys {
            guard let option = options[key] else { continue }
            try applyUIOption(key, option, to: &element, line: line)
        }
    }

    private func applyUIOption(_ key: String, _ value: ScriptValue, to element: inout UIElement, line: Int) throws {
        func finite(_ what: String) throws -> Double { try number(value, what, line) }
        switch key {
        case "at":
            guard let preset = UIElement.presets[value.displayText.lowercased()] else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“at” is one of: {}.", UIElement.presets.keys.sorted().joined(separator: ", ")))
            }
            element.place(at: preset)
        case "x": element.x = try finite(key)
        case "y": element.y = try finite(key)
        case "pivot":
            guard let preset = UIElement.presets[value.displayText.lowercased()] else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“pivot” is one of: {}.", UIElement.presets.keys.sorted().joined(separator: ", ")))
            }
            element.pivotX = preset.x
            element.pivotY = preset.y
        case "dx": element.offsetX = try finite(key)
        case "dy": element.offsetY = try finite(key)
        case "w", "width": element.width = value.isNull ? nil : Swift.min(Swift.max(try finite(key), 0), 4_000)
        case "h", "height": element.height = value.isNull ? nil : Swift.min(Swift.max(try finite(key), 0), 4_000)
        case "color": element.color = value.isNull ? nil : try color(value, line: line)
        case "bg", "background": element.background = value.isNull ? nil : try color(value, line: line)
        case "size":
            switch value {
            case let .number(n) where n.isFinite:
                element.fontSize = Swift.min(Swift.max(n, 6), 300)
            default:
                let named: [String: Double] = ["small": 14, "medium": 18, "large": 28, "huge": 48]
                guard let size = named[value.displayText.lowercased()] else {
                    throw ScriptError(line: line, kind: .runtime, message: L("“size” is a number, or “small”, “medium”, “large” or “huge”."))
                }
                element.fontSize = size
            }
        case "bold": element.bold = value.isTruthy
        case "radius": element.cornerRadius = Swift.min(Swift.max(try finite(key), 0), 1_000)
        case "opacity": element.opacity = Swift.min(Swift.max(try finite(key), 0), 1)
        case "visible": element.visible = value.isTruthy
        case "layer": element.layer = Int(Swift.min(Swift.max(try finite(key), -1_000), 1_000))
        case "parent":
            let parent = value.isNull ? "" : uiID(value)
            element.parent = parent.isEmpty || parent == element.id ? nil : parent
        case "text": element.text = shortText(value)
        case "value": element.value = try finite(key)
        case "max":
            let maximum = try finite(key)
            guard maximum > 0 else {
                throw ScriptError(line: line, kind: .runtime, message: L("A bar’s maximum has to be more than 0."))
            }
            element.maximum = maximum
        default:
            throw ScriptError(line: line, kind: .runtime,
                              message: L("A screen item has no “{}”. It can have: {}.", key, Self.uiOptionNames.joined(separator: ", ")))
        }
    }

    private func existingUI(_ id: String, owner: PlayerState?) -> UIElement? {
        if let owner { return owner.ui[id] ?? globalUI[id] }
        return globalUI[id]
    }

    /// Shows an element to one player, or to everyone when `owner` is nil.
    private func showUI(_ element: UIElement, owner: PlayerState?, line: Int) throws {
        let limit = UIElement.Limits.maximumElements
        if let owner {
            guard !owner.isNPC else { return }
            if owner.ui[element.id] == nil, globalUI[element.id] == nil, owner.ui.count + globalUI.count >= limit {
                throw ScriptError(line: line, kind: .limit, message: L("Too many things on the screen (the limit is {}).", limit))
            }
            owner.ui[element.id] = element
            send(owner, .script(.ui(element)))
        } else {
            if globalUI[element.id] == nil {
                let busiest = states.values.map(\.ui.count).max() ?? 0
                guard globalUI.count + busiest < limit else {
                    throw ScriptError(line: line, kind: .limit, message: L("Too many things on the screen (the limit is {}).", limit))
                }
                globalUIOrder.append(element.id)
            }
            globalUI[element.id] = element
            pending.append(broadcast(.script(.ui(element))))
        }
    }

    private func removeUI(_ id: String, owner: PlayerState?) {
        // What sits inside a removed panel goes with it.
        func descendants(of root: String, in elements: [String: UIElement]) -> Set<String> {
            var found: Set<String> = [root]
            var grew = true
            while grew {
                let before = found.count
                for element in elements.values where element.parent.map(found.contains) == true {
                    found.insert(element.id)
                }
                grew = found.count > before
            }
            return found
        }
        if let owner {
            for doomed in descendants(of: id, in: owner.ui) { owner.ui[doomed] = nil }
            send(owner, .script(.removeUI(id: id)))
        } else {
            let doomed = descendants(of: id, in: globalUI)
            for gone in doomed { globalUI[gone] = nil }
            globalUIOrder.removeAll { doomed.contains($0) }
            pending.append(broadcast(.script(.removeUI(id: id))))
        }
    }

    private func clearUI(owner: PlayerState?) {
        if let owner {
            owner.ui.removeAll()
            // The client clears the lot, so what everyone sees is put back.
            send(owner, .script(.clearUI))
            for id in globalUIOrder {
                if let element = globalUI[id] { send(owner, .script(.ui(element))) }
            }
        } else {
            globalUI.removeAll()
            globalUIOrder.removeAll()
            for state in states.values { state.ui.removeAll() }
            pending.append(broadcast(.script(.clearUI)))
        }
    }

    /// The id from a text or from a screen-item handle.
    private func uiID(_ value: ScriptValue) -> String {
        if case let .object(object) = value, object.kind == "ui" {
            return String(object.id.split(separator: "|", maxSplits: 1).last ?? "")
        }
        return value.displayText
    }

    private func uiHandle(_ id: String, owner: PlayerState?) -> ScriptValue {
        let ownerKey = owner?.peer.raw.uuidString ?? "*"
        return .object(ScriptObject(kind: "ui", id: "\(ownerKey)|\(id)", displayName: id))
    }

    private func uiOwner(_ object: ScriptObject) -> (owner: PlayerState?, id: String, known: Bool) {
        let parts = object.id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (nil, object.displayName, false) }
        if parts[0] == "*" { return (nil, parts[1], true) }
        guard let uuid = UUID(uuidString: parts[0]), let owner = states[PeerID(uuid)] else { return (nil, parts[1], false) }
        return (owner, parts[1], true)
    }

    private func uiMember(_ object: ScriptObject, _ name: String, line: Int) throws -> ScriptValue {
        let (owner, id, known) = uiOwner(object)
        guard known, let element = existingUI(id, owner: owner) else {
            return name == "id" ? .string(id) : .null
        }
        switch name {
        case "id": return .string(element.id)
        case "kind": return .string(element.kind.rawValue)
        case "text": return .string(element.text)
        case "value": return .number(element.value)
        case "max": return .number(element.maximum)
        case "x": return .number(element.x)
        case "y": return .number(element.y)
        case "visible": return .bool(element.visible)
        case "parent": return element.parent.map { .string($0) } ?? .null
        case "remove":
            return method(name) { [unowned self] _, _ in
                self.removeUI(id, owner: owner)
                return .null
            }
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("A screen item has no “{}”.", name))
        }
    }

    private func setUIMember(_ object: ScriptObject, _ name: String, _ value: ScriptValue, line: Int) throws {
        let (owner, id, known) = uiOwner(object)
        guard known, var element = existingUI(id, owner: owner) else { return }
        try applyUIOption(name, value, to: &element, line: line)
        try showUI(element, owner: owner, line: line)
    }

    // MARK: Screen effects

    private func fadeEffect(_ arguments: [ScriptValue], line: Int) throws -> ScriptEffect {
        let color: ColorRGBA? = arguments.isEmpty || arguments[0].isNull ? nil : try self.color(arguments[0], line: line)
        let seconds = Swift.min(Swift.max(try optionalNumber(arguments, 1, default: 0.5, line: line), 0), 60)
        return .fade(color: color, seconds: seconds)
    }

    private func shakeEffect(_ arguments: [ScriptValue], line: Int) throws -> ScriptEffect {
        let strength = Swift.min(Swift.max(try optionalNumber(arguments, 0, default: 0.3, line: line), 0), 5)
        let seconds = Swift.min(Swift.max(try optionalNumber(arguments, 1, default: 0.4, line: line), 0), 30)
        return .shake(strength: Float(strength), seconds: seconds)
    }

    // MARK: Raycast

    /// `raycast(from, direction, range)`: the first thing along a line, as
    /// `{point, distance, block, player}`, or nil.
    private func raycast(_ arguments: [ScriptValue], line: Int) throws -> ScriptValue {
        guard arguments.count >= 2 else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", "raycast", 2))
        }
        var origin = try point(arguments[0], line: line)
        let from = characterArgument(arguments, 0)
        if let from { origin.y += PlayerHitBody.eyeHeight * from.profile.height }
        let direction = try vector(arguments[1], line: line)
        let range = Float(Swift.min(Swift.max(try optionalNumber(arguments, 2, default: 100, line: line), 0.1), 5_000))
        let result = cast(from: origin, direction: direction, range: range, ignoring: from?.peer)

        let map = ScriptMap()
        map["point"] = vectorValue(result.point)
        map["distance"] = .number(Double(result.distance))
        switch result.target {
        case .nothing:
            return .null
        case let .block(id):
            map["block"] = blockObject(id)
        case let .player(peer):
            if let state = states[peer] { map["player"] = object(for: state) }
        }
        return .map(map)
    }

    // MARK: Timers and weapons

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
        let options = arguments.count > 1 ? try optionsMap(arguments[1], line: line) : ScriptMap()
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

    // MARK: Reading arguments

    func method(_ name: String, _ body: @escaping ([ScriptValue], Int) throws -> ScriptValue) -> ScriptValue {
        .native(ScriptNative(name, body))
    }

    func number(_ value: ScriptValue, _ what: String, _ line: Int) throws -> Double {
        guard case let .number(number) = value, number.isFinite else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("“{}” needs a number here, not {}.", what, value.isNull ? "nil" : value.displayText))
        }
        return number
    }

    func optionalNumber(_ arguments: [ScriptValue], _ index: Int, default fallback: Double, line: Int) throws -> Double {
        guard index < arguments.count, !arguments[index].isNull else { return fallback }
        return try number(arguments[index], "number", line)
    }

    func shortText(_ value: ScriptValue) -> String {
        String(value.displayText.prefix(UIElement.Limits.maximumTextLength))
    }

    private func optionsMap(_ value: ScriptValue, line: Int) throws -> ScriptMap {
        switch value {
        case let .map(map): return map
        case .null: return ScriptMap()
        default:
            throw ScriptError(line: line, kind: .runtime, message: L("This needs options in { }, like {x: 0.5, y: 0.1}."))
        }
    }

    private func soundCue(_ value: ScriptValue, line: Int) throws -> SoundCue {
        guard let cue = SoundCue.named(value.displayText) else {
            throw ScriptError(line: line, kind: .runtime, message: L("There is no sound called “{}”. The sounds are: {}.",
                                                                     value.displayText,
                                                                     SoundCue.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        return cue
    }

    func vectorValue(_ position: Vec3) -> ScriptValue {
        ScriptVector(Self.rounded(position.x), Self.rounded(position.y), Self.rounded(position.z)).value
    }

    /// Positions to the centimetre, so `print(p.position)` is readable.
    static func rounded(_ value: Float) -> Double {
        (Double(value) * 100).rounded() / 100
    }

    /// A `{x, y, z}` map as a vector.
    func vector(_ value: ScriptValue, line: Int) throws -> Vec3 {
        guard let vector = ScriptVector(value), vector.isFinite else {
            throw ScriptError(line: line, kind: .runtime, message: L("That needs {x, y, z}, not {}.", value.typeName))
        }
        return vector.vec3
    }

    /// Three numbers, or one `{x, y, z}`.
    private func vectorArgument(_ arguments: [ScriptValue], line: Int, what: String) throws -> Vec3 {
        if let first = arguments.first, ScriptVector(first) != nil { return try vector(first, line: line) }
        guard arguments.count >= 3 else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs {} values.", what, 3))
        }
        return Vec3(Float(try number(arguments[0], what, line)),
                    Float(try number(arguments[1], what, line)),
                    Float(try number(arguments[2], what, line)))
    }

    /// Where a player, an NPC, a block or a `{x, y, z}` map is.
    func point(_ value: ScriptValue, line: Int) throws -> Vec3 {
        switch value {
        case let .object(object):
            if let state = character(object), let position = position(of: state) { return position }
            if let id = blockID(object) { return worldIndex.entry(for: id)?.position ?? world.worldPosition(of: id) }
        case .map:
            return try vector(value, line: line)
        default:
            break
        }
        throw ScriptError(line: line, kind: .runtime,
                          message: L("That needs a player, a block or a position like {x: 0, y: 5, z: 0}, not {}.", value.typeName))
    }

    /// Where `teleport` lands: on top of a block, at a character, at a
    /// position, or at three numbers.
    private func destination(_ arguments: [ScriptValue], line: Int) throws -> Vec3 {
        if arguments.count >= 3 { return try vectorArgument(arguments, line: line, what: "teleport") }
        let value = arguments.first ?? .null
        if case let .object(object) = value, let id = blockID(object) {
            // A metre above the top face, as checkpoints do, so nobody lands
            // inside the block.
            if let entry = worldIndex.entry(for: id) {
                let bounds = entry.bounds
                let centre = entry.position
                return Vec3(centre.x, bounds.max.y + 1, centre.z)
            }
        }
        return try point(value, line: line)
    }

    private func optionalPoint(_ options: ScriptMap, line: Int) throws -> Vec3? {
        if let position = options["position"] { return try point(position, line: line) }
        guard options["x"] != nil || options["y"] != nil || options["z"] != nil else { return nil }
        return Vec3(Float(try optionalNumber([options["x"] ?? .null], 0, default: 0, line: line)),
                    Float(try optionalNumber([options["y"] ?? .null], 0, default: 2, line: line)),
                    Float(try optionalNumber([options["z"] ?? .null], 0, default: 0, line: line)))
    }

    private func characterArgument(_ arguments: [ScriptValue], _ index: Int) -> PlayerState? {
        guard index < arguments.count, case let .object(object) = arguments[index] else { return nil }
        return character(object)
    }

    func color(_ value: ScriptValue, line: Int) throws -> ColorRGBA {
        guard let color = ScriptColor.parse(value.displayText) else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("“{}” is not a colour. Try “red”, “blue” or “#FF8800”.", value.displayText))
        }
        return color
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
        "gold": "#F59E0B", "clear": "#00000000",
        "赤": "#EF4444", "オレンジ": "#F97316", "黄": "#FACC15", "黄色": "#FACC15", "緑": "#22C55E",
        "青": "#3B82F6", "水色": "#22D3EE", "紫": "#A855F7", "ピンク": "#EC4899",
        "白": "#FFFFFF", "黒": "#111111", "灰色": "#9CA3AF", "茶色": "#92400E", "金": "#F59E0B", "透明": "#00000000"
    ]

    public static func parse(_ text: String) -> ColorRGBA? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = named[key.lowercased()] ?? named[key] { return ColorRGBA(hex: hex) }
        guard key.hasPrefix("#") else { return nil }
        return ColorRGBA(hex: key)
    }
}
