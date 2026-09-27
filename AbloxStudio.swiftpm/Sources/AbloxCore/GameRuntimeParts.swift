import Foundation

// The ready-made parts a script can use without building them itself:
// things to carry, conversations with answers, shops, countdowns, a
// world's leaderboards, particles, sounds and music, speech, the arrow that
// points the way, the weather and the time of day — and the no-script
// blocks that need the player: vehicles and pushable blocks.

extension GameRuntime {

    public static let partsAPINames: [String] = [
        "particles", "music", "speak", "countdown", "leaderboard", "show_leaderboard", "leaderboard_top"
    ]

    /// Members a person has for the parts.
    public static let partsMemberNames: [String] = [
        "give_item", "take_item", "has_item", "items", "clear_items", "dialog", "close_dialog",
        "shop", "close_shop", "waypoint", "music", "speak", "countdown", "show_leaderboard", "particles", "vehicle"
    ]

    public static let partsWorldMemberNames: [String] = [
        "weather", "time", "day_length", "sky_style", "effect", "shadows", "music"
    ]

    // MARK: Leaderboards, kept by the host

    /// What the host saved for this world last time.
    public func loadLeaderboards(_ boards: [String: Leaderboard]) {
        leaderboards = boards
        leaderboardsChanged = false
    }

    /// The boards when they changed since the last call, for the host to keep.
    public func takeLeaderboardsIfChanged() -> [String: Leaderboard]? {
        guard leaderboardsChanged else { return nil }
        leaderboardsChanged = false
        return leaderboards
    }

    // MARK: Globals

    func installPartsAPI(on interpreter: ScriptInterpreter) {
        interpreter.define("particles") { [unowned self] arguments, line in
            let burst = try self.particleBurst(arguments, line: line)
            self.pending.append(self.broadcast(.script(.particles(burst))))
            return .null
        }
        interpreter.define("music") { [unowned self] arguments, line in
            self.pending.append(self.broadcast(.script(.music(try self.musicPlay(arguments, line: line)))))
            return .null
        }
        interpreter.define("speak") { [unowned self] arguments, _ in
            self.pending.append(self.broadcast(.script(.speak(self.shortText(arguments.first ?? .null)))))
            return .null
        }
        interpreter.define("countdown") { [unowned self] arguments, line in
            try self.startCountdown(arguments, for: nil, line: line)
            return .null
        }
        interpreter.define("leaderboard") { [unowned self] arguments, line in
            try self.submitScore(arguments, line: line)
        }
        interpreter.define("show_leaderboard") { [unowned self] arguments, line in
            let name = (arguments.first ?? .null).displayText
            guard let board = self.leaderboards[name] else {
                throw ScriptError(line: line, kind: .runtime, message: L("There is no leaderboard called “{}” yet.", name))
            }
            if let state = self.characterArgument(arguments, 1) {
                self.send(state, .script(.leaderboard(LeaderboardPanel(board))))
            } else {
                self.pending.append(self.broadcast(.script(.leaderboard(LeaderboardPanel(board)))))
            }
            return .null
        }
        interpreter.define("leaderboard_top") { [unowned self] arguments, line in
            let name = (arguments.first ?? .null).displayText
            let count = Int(try self.optionalNumber(arguments, 1, default: 10, line: line))
            let rows = (self.leaderboards[name]?.rows ?? []).prefix(Swift.max(0, count))
            return .list(ScriptList(rows.map { row in
                let map = ScriptMap()
                map["name"] = .string(row.name)
                map["value"] = .number(row.value)
                return .map(map)
            }))
        }
    }

    // MARK: A person's members

    /// The parts' members of a person, or nil when `name` is not one of them.
    func partsMember(_ state: PlayerState, _ name: String) -> ScriptValue? {
        switch name {
        case "items":
            let map = ScriptMap()
            for item in state.items { map[item.name] = .number(Double(item.count)) }
            return .map(map)
        case "vehicle":
            return state.vehicle.map { .string($0.rawValue) } ?? .null
        case "give_item":
            return method(name) { [unowned self] arguments, line in
                let item = self.shortName(arguments.first ?? .null)
                guard !item.isEmpty else { throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a name.", "give_item")) }
                let count = Int(try self.optionalNumber(arguments, 1, default: 1, line: line))
                let icon = arguments.count > 2 ? String(arguments[2].displayText.prefix(40)) : ""
                self.changeItems(state) { items in
                    if let index = items.firstIndex(where: { $0.name == item }) {
                        items[index].count = Swift.min(999_999, items[index].count + Swift.max(1, count))
                        if !icon.isEmpty { items[index].icon = icon }
                    } else if items.count < InventoryItem.maximumItems {
                        items.append(InventoryItem(name: item, icon: icon, count: Swift.max(1, count)))
                    }
                }
                return .null
            }
        case "take_item":
            return method(name) { [unowned self] arguments, line in
                let item = self.shortName(arguments.first ?? .null)
                let count = Int(try self.optionalNumber(arguments, 1, default: 1, line: line))
                guard let have = state.items.first(where: { $0.name == item }), have.count >= count else { return .bool(false) }
                self.changeItems(state) { items in
                    guard let index = items.firstIndex(where: { $0.name == item }) else { return }
                    items[index].count -= count
                    if items[index].count <= 0 { items.remove(at: index) }
                }
                return .bool(true)
            }
        case "has_item":
            return method(name) { [unowned self] arguments, line in
                let item = self.shortName(arguments.first ?? .null)
                let count = Int(try self.optionalNumber(arguments, 1, default: 1, line: line))
                return .bool((state.items.first { $0.name == item }?.count ?? 0) >= count)
            }
        case "clear_items":
            return method(name) { [unowned self] _, _ in
                self.changeItems(state) { $0.removeAll() }
                return .null
            }
        case "dialog":
            // p.dialog("Shopkeeper", "Want a sword?", ["Yes", "No"])
            return method(name) { [unowned self] arguments, line in
                let speaker = self.shortText(arguments.first ?? .null)
                let text = arguments.count > 1 ? String(arguments[1].displayText.prefix(400)) : ""
                var choices: [String] = []
                if arguments.count > 2 {
                    guard case let .list(list) = arguments[2] else {
                        throw ScriptError(line: line, kind: .runtime, message: L("The answers go in a list, like [\"Yes\", \"No\"]."))
                    }
                    choices = list.items.map(\.displayText)
                }
                let box = DialogBox(id: String(self.clock.bitPattern, radix: 36), speaker: speaker, text: text,
                                    choices: choices.isEmpty ? [L("OK")] : choices)
                state.dialog = box
                self.send(state, .script(.dialog(box)))
                return .null
            }
        case "close_dialog":
            return method(name) { [unowned self] _, _ in
                state.dialog = nil
                self.send(state, .script(.dialog(nil)))
                return .null
            }
        case "shop":
            // p.shop("Weapons", [{name: "Sword", price: 50, icon: "⚔️"}], {currency: "coins"})
            return method(name) { [unowned self] arguments, line in
                try self.openShop(arguments, for: state, line: line)
                return .null
            }
        case "close_shop":
            return method(name) { [unowned self] _, _ in
                state.shop = nil
                self.send(state, .script(.shop(nil)))
                return .null
            }
        case "waypoint":
            // p.waypoint(block("Exit"), "The exit"), p.waypoint(nil)
            return method(name) { [unowned self] arguments, line in
                let target = arguments.first ?? .null
                guard !target.isNull else {
                    self.send(state, .script(.waypoint(nil)))
                    return .null
                }
                let label = arguments.count > 1 ? self.shortText(arguments[1]) : ""
                let color = arguments.count > 2 ? try self.color(arguments[2], line: line) : nil
                self.send(state, .script(.waypoint(Waypoint(position: try self.point(target, line: line), label: label, color: color))))
                return .null
            }
        case "music":
            return method(name) { [unowned self] arguments, line in
                self.send(state, .script(.music(try self.musicPlay(arguments, line: line))))
                return .null
            }
        case "speak":
            return method(name) { [unowned self] arguments, _ in
                self.send(state, .script(.speak(self.shortText(arguments.first ?? .null))))
                return .null
            }
        case "countdown":
            return method(name) { [unowned self] arguments, line in
                try self.startCountdown(arguments, for: state, line: line)
                return .null
            }
        case "show_leaderboard":
            return method(name) { [unowned self] arguments, line in
                let board = (arguments.first ?? .null).displayText
                guard let found = self.leaderboards[board] else {
                    throw ScriptError(line: line, kind: .runtime, message: L("There is no leaderboard called “{}” yet.", board))
                }
                self.send(state, .script(.leaderboard(LeaderboardPanel(found))))
                return .null
            }
        case "particles":
            return method(name) { [unowned self] arguments, line in
                // Around this person, seen by everyone.
                var burst = try self.particleBurst([arguments.first ?? .null, self.object(for: state)] + arguments.dropFirst(), line: line)
                burst.position.y += 1
                self.pending.append(self.broadcast(.script(.particles(burst))))
                return .null
            }
        default:
            return nil
        }
    }

    private func shortName(_ value: ScriptValue) -> String {
        String(value.displayText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    }

    private func changeItems(_ state: PlayerState, _ change: (inout [InventoryItem]) -> Void) {
        var items = state.items
        change(&items)
        guard items != state.items else { return }
        state.items = items
        send(state, .script(.inventory(items)))
    }

    private func openShop(_ arguments: [ScriptValue], for state: PlayerState, line: Int) throws {
        let title = shortText(arguments.first ?? .null)
        guard arguments.count > 1, case let .list(list) = arguments[1] else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("A shop needs a list of things, like [{name: \"Sword\", price: 50}]."))
        }
        var offers: [ShopOffer] = []
        for entry in list.items.prefix(ShopPanel.maximumOffers) {
            let map = try optionsMap(entry, line: line)
            let name = (map["name"] ?? .null).displayText
            guard !name.isEmpty else { continue }
            let price = Int(try optionalNumber([map["price"] ?? .null], 0, default: 0, line: line))
            offers.append(ShopOffer(name: name, price: price, icon: (map["icon"] ?? .null).isNull ? "" : (map["icon"] ?? .null).displayText))
        }
        let options = try optionsMap(arguments.count > 2 ? arguments[2] : .null, line: line)
        let currency = options["currency"].map(\.displayText) ?? "coins"
        state.shopCurrency = currency
        let panel = ShopPanel(id: String(clock.bitPattern, radix: 36), title: title, currency: currency,
                              balance: balance(of: state, in: currency), offers: offers)
        state.shop = panel
        send(state, .script(.shop(panel)))
    }

    /// A player's money for a shop: the number the script keeps on them
    /// (`p.coins = 100`), or their score for "score".
    private func balance(of state: PlayerState, in currency: String) -> Int {
        if currency == "score" { return snapshot(of: state)?.score ?? 0 }
        if case let .number(value) = state.custom[currency] ?? .null, value.isFinite { return Int(value) }
        return 0
    }

    private func musicPlay(_ arguments: [ScriptValue], line: Int) throws -> MusicPlay? {
        let first = arguments.first ?? .null
        guard !first.isNull else { return nil }
        // Quiet, rather than back to the world's own music.
        if ["none", "off", "stop"].contains(first.displayText.lowercased()) { return MusicPlay(track: "none", volume: 0) }
        guard let track = MusicTrack(rawValue: first.displayText.lowercased()) else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("There is no music called “{}”. The music is: {}.", first.displayText,
                                         MusicTrack.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        let options = try optionsMap(arguments.count > 1 ? arguments[1] : .null, line: line)
        let volume = try optionalNumber([options["volume"] ?? .null], 0, default: 1, line: line)
        return MusicPlay(track: track.rawValue, volume: Float(volume))
    }

    /// `particles("fire", where, {seconds: 2, amount: 40, color: "red"})`.
    func particleBurst(_ arguments: [ScriptValue], line: Int) throws -> ParticleBurst {
        let name = (arguments.first ?? .null).displayText.lowercased()
        guard let kind = ParticleKind(rawValue: name) else {
            throw ScriptError(line: line, kind: .runtime,
                              message: L("There are no particles called “{}”. Try: {}.", name,
                                         ParticleKind.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        let position = try point(arguments.count > 1 ? arguments[1] : .null, line: line)
        let options = try optionsMap(arguments.count > 2 ? arguments[2] : .null, line: line)
        let seconds = try optionalNumber([options["seconds"] ?? .null], 0, default: 0, line: line)
        let amount = try optionalNumber([options["amount"] ?? .null], 0, default: 30, line: line)
        let color = try options["color"].map { try self.color($0, line: line) }
        return ParticleBurst(kind: kind, position: position, amount: Int(amount), seconds: seconds, color: color)
    }

    /// `sound("coin", {volume: 0.5, pitch: 1.5})` — with options, the
    /// numbers-made sound; without, the classic cue.
    func soundEffect(_ arguments: [ScriptValue], line: Int) throws -> EventAction {
        let cue = try soundCue(arguments.first ?? .null, line: line)
        guard arguments.count > 1, !arguments[1].isNull else { return .playSound(name: cue.rawValue) }
        let options = try optionsMap(arguments[1], line: line)
        let volume = try optionalNumber([options["volume"] ?? .null], 0, default: 1, line: line)
        let pitch = try optionalNumber([options["pitch"] ?? .null], 0, default: 1, line: line)
        return .script(.sound(SoundPlay(name: cue.rawValue, volume: Float(volume), pitch: Float(pitch))))
    }

    // MARK: Countdowns

    private func startCountdown(_ arguments: [ScriptValue], for state: PlayerState?, line: Int) throws {
        let first = arguments.first ?? .null
        let label = arguments.count > 1 ? shortText(arguments[1]) : ""
        if first.isNull {
            countdowns.removeAll { $0.peer == state?.peer && (label.isEmpty || $0.label == label) }
            let effect = ScriptEffect.countdown(nil)
            if let state { send(state, .script(effect)) } else { pending.append(broadcast(.script(effect))) }
            return
        }
        let seconds = Swift.max(0, Swift.min(86_400, try number(first, "countdown", line)))
        countdowns.removeAll { $0.peer == state?.peer && $0.label == label }
        countdowns.append((label: label, due: clock + seconds, peer: state?.peer))
        let effect = ScriptEffect.countdown(CountdownDisplay(label: label, seconds: seconds))
        if let state { send(state, .script(effect)) } else { pending.append(broadcast(.script(effect))) }
    }

    func advanceCountdowns() {
        guard !countdowns.isEmpty else { return }
        let due = countdowns.filter { $0.due <= clock }
        guard !due.isEmpty else { return }
        countdowns.removeAll { $0.due <= clock }
        for item in due {
            let person = item.peer.flatMap { states[$0] }
            if let person { send(person, .script(.countdown(nil))) } else { pending.append(broadcast(.script(.countdown(nil)))) }
            run(.countdown, [.string(item.label), person.map { object(for: $0) } ?? .null])
        }
    }

    // MARK: Leaderboards

    /// `leaderboard("fastest", p, time, {lower: true})`: keeps the player's
    /// best, returns their place (1 is top) or nil when off the table.
    private func submitScore(_ arguments: [ScriptValue], line: Int) throws -> ScriptValue {
        let name = String((arguments.first ?? .null).displayText.prefix(40))
        guard !name.isEmpty, let state = characterArgument(arguments, 1), !state.isNPC else {
            throw ScriptError(line: line, kind: .runtime, message: L("“{}” needs a name, a player and a number.", "leaderboard"))
        }
        let value = try number(arguments.count > 2 ? arguments[2] : .null, "leaderboard", line)
        let options = try optionsMap(arguments.count > 3 ? arguments[3] : .null, line: line)
        var board = leaderboards[name] ?? Leaderboard(title: name, lowerIsBetter: options["lower"]?.isTruthy ?? false)
        guard leaderboards[name] != nil || leaderboards.count < 20 else {
            throw ScriptError(line: line, kind: .limit, message: L("A world can keep at most {} leaderboards.", 20))
        }
        if board.submit(name: state.name, value: value) {
            leaderboards[name] = board
            leaderboardsChanged = true
        }
        return board.rank(of: state.name).map { .number(Double($0)) } ?? .null
    }

    // MARK: The runtime's own buttons

    func handleReserved(_ button: ReservedButton, from state: PlayerState) {
        switch button {
        case let .use(item):
            guard state.items.contains(where: { $0.name == item }) else { return }
            run(.use, [object(for: state), .string(item)])

        case let .choose(dialogID, index):
            guard let dialog = state.dialog, dialog.id == dialogID, dialog.choices.indices.contains(index) else { return }
            state.dialog = nil
            send(state, .script(.dialog(nil)))
            run(.choice, [object(for: state), .string(dialog.choices[index]), .number(Double(index + 1))])

        case let .buy(shopID, item):
            guard let shop = state.shop, shop.id == shopID, let offer = shop.offers.first(where: { $0.name == item }) else { return }
            let money = balance(of: state, in: state.shopCurrency)
            guard money >= offer.price else {
                send(state, .announce(message: L("Not enough {}.", L(state.shopCurrency)), duration: 2))
                send(state, .playSound(name: SoundCue.error.rawValue))
                return
            }
            if state.shopCurrency == "score" {
                setScore(state, to: money - offer.price)
            } else {
                state.custom[state.shopCurrency] = .number(Double(money - offer.price))
            }
            send(state, .playSound(name: SoundCue.coin.rawValue))
            run(.buy, [object(for: state), .string(offer.name), .number(Double(offer.price))])
            // The window stays open with the new balance, unless the
            // handler closed it.
            if var open = state.shop, open.id == shopID {
                open.balance = balance(of: state, in: state.shopCurrency)
                state.shop = open
                send(state, .script(.shop(open)))
            }

        case .closeDialog:
            guard state.dialog != nil else { return }
            state.dialog = nil
            send(state, .script(.dialog(nil)))

        case .closeShop:
            guard state.shop != nil else { return }
            state.shop = nil
            send(state, .script(.shop(nil)))

        case .closeLeaderboard:
            send(state, .script(.leaderboard(nil)))

        case .exitVehicle:
            leaveVehicle(state)
        }
    }

    // MARK: Vehicles and pushing

    func partsTouched(_ state: PlayerState, blockID: UUID) {
        guard state.isAlive, !state.isNPC, let block = world.block(id: blockID) else { return }
        switch block.behavior {
        case .vehicle:
            enterVehicle(state, block: block)
        case .pushable:
            push(blockID, by: state)
        default:
            break
        }
    }

    private func enterVehicle(_ state: PlayerState, block: BlockData) {
        guard state.vehicle == nil,
              let ride = AvatarProfile.Ride(rawValue: block.gimmick.vehicle.lowercased()), ride != .none else { return }
        state.vehicle = ride
        state.movementBeforeVehicle = state.movement
        var movement = state.movement
        movement.speed *= Swift.max(0.5, Swift.min(4, block.gimmick.vehicleSpeed))
        state.movement = movement
        send(state, .script(.movement(movement)))
        updateProfile(state) { $0.ride = ride; $0.rideColor = block.color }
        send(state, .script(.vehicle(true)))
        send(state, .playSound(name: SoundCue.door.rawValue))
    }

    func leaveVehicle(_ state: PlayerState) {
        guard state.vehicle != nil else { return }
        state.vehicle = nil
        let movement = state.movementBeforeVehicle ?? .normal
        state.movementBeforeVehicle = nil
        state.movement = movement
        send(state, .script(.movement(movement)))
        updateProfile(state) { $0.ride = .none }
        send(state, .script(.vehicle(false)))
    }

    /// One step along the side it was walked into — along a grid line, so
    /// boxes line up for puzzles — unless something solid is in the way. It
    /// drops if there is nothing under it.
    private func push(_ blockID: UUID, by state: PlayerState) {
        if let last = lastPush[blockID], clock - last < 0.35 { return }
        guard let feet = position(of: state), let bounds = worldIndex.bounds(of: blockID) else { return }
        var away = bounds.center - feet
        away.y = 0
        guard away.length > 0.05 else { return }
        let step: Vec3 = abs(away.x) > abs(away.z) ? Vec3(away.x > 0 ? 1 : -1, 0, 0) : Vec3(0, 0, away.z > 0 ? 1 : -1)
        let moved = BoundingBox(min: bounds.min + step, max: bounds.max + step).expanded(by: -0.05)
        let blocked = worldIndex.entries(near: moved).contains { entry in
            entry.id != blockID && entry.isVisible && entry.hasCollision && moved.penetrates(entry.bounds)
        }
        guard !blocked else { return }
        lastPush[blockID] = clock
        let drop = dropBelow(moved, ignoring: blockID)
        moveBlock(blockID, by: step + Vec3(0, -drop, 0), over: 0.3 + Double(drop) * 0.06)
    }

    /// How far a box would fall onto whatever is under it.
    private func dropBelow(_ box: BoundingBox, ignoring id: UUID) -> Float {
        let floor = world.environment.killPlaneHeight
        let column = BoundingBox(min: Vec3(box.min.x, Swift.max(floor, box.min.y - 60), box.min.z),
                                 max: Vec3(box.max.x, box.min.y, box.max.z))
        var highest = floor - 10
        for entry in worldIndex.entries(near: column) where entry.id != id && entry.isVisible && entry.hasCollision {
            let top = entry.bounds.max.y
            if top <= box.min.y + 0.1, top > highest, column.intersects(entry.bounds) { highest = top }
        }
        return Swift.max(0, Swift.min(60, box.min.y + 0.05 - highest))
    }

    // MARK: The world: weather, time, sky

    func partsWorldMember(_ name: String) -> ScriptValue? {
        let environment = world.environment
        switch name {
        case "weather": return .string(environment.weather.rawValue)
        case "time":
            guard let hour = environment.hour(atWallClock: wallClock()) else { return .null }
            return .number((Double(hour) * 100).rounded() / 100)
        case "day_length": return .number(Double(environment.dayLengthMinutes))
        case "sky_style": return .string(environment.skyStyle.rawValue)
        case "effect": return .string(environment.screenEffect.rawValue)
        case "shadows": return .bool(environment.shadows)
        case "music": return environment.music.map { .string($0.rawValue) } ?? .null
        default: return nil
        }
    }

    /// True when `name` was one of the parts' world settings.
    func setPartsWorldMember(_ name: String, _ value: ScriptValue, into environment: inout EnvironmentSettings, line: Int) throws -> Bool {
        func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type) throws -> T where T.RawValue == String {
            let text = value.displayText.lowercased()
            guard let found = T(rawValue: text) else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("“{}” is one of: {}.", name, T.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            return found
        }
        switch name {
        case "weather": environment.weather = try choice(Weather.self)
        case "time":
            if value.isNull {
                environment.timeOfDay = nil
            } else {
                // Counted from now.
                environment.timeOfDay = DayCycle.hour(start: Float(try number(value, name, line)), dayLengthMinutes: 0, elapsed: 0)
                environment.dayEpoch = wallClock()
            }
        case "day_length":
            // The hour it is now stays where it is; only the speed changes.
            let now = environment.hour(atWallClock: wallClock()) ?? 12
            environment.dayLengthMinutes = Float(Swift.max(0, Swift.min(1_440, try number(value, name, line))))
            environment.timeOfDay = now
            environment.dayEpoch = wallClock()
        case "sky_style": environment.skyStyle = try choice(SkyStyle.self)
        case "effect": environment.screenEffect = try choice(ScreenEffect.self)
        case "shadows": environment.shadows = value.isTruthy
        case "music": environment.music = value.isNull ? nil : try choice(MusicTrack.self)
        default: return false
        }
        return true
    }

    // MARK: Blocks

    func partsBlockMember(_ block: BlockData, _ name: String) -> ScriptValue? {
        switch name {
        case "particles": return block.particles.map { .string($0.rawValue) } ?? .null
        case "image": return block.imageID.flatMap { id in world.image(id: id)?.name }.map { .string($0) } ?? .null
        default: return nil
        }
    }

    /// True when `name` was one of the parts' block settings.
    func setPartsBlockMember(_ name: String, _ value: ScriptValue, to block: inout BlockData, line: Int) throws -> Bool {
        switch name {
        case "particles":
            if value.isNull {
                block.particles = nil
            } else if let found = ParticleKind(rawValue: value.displayText.lowercased()) {
                block.particles = found
            } else {
                throw ScriptError(line: line, kind: .runtime,
                                  message: L("There are no particles called “{}”. Try: {}.", value.displayText,
                                             ParticleKind.allCases.map(\.rawValue).joined(separator: ", ")))
            }
        case "image":
            if value.isNull {
                block.imageID = nil
            } else if let found = world.images.first(where: { $0.name.caseInsensitiveCompare(value.displayText) == .orderedSame }) {
                block.imageID = found.id
            } else {
                throw ScriptError(line: line, kind: .runtime, message: L("This world has no picture called “{}”.", value.displayText))
            }
        default:
            return false
        }
        return true
    }
}
