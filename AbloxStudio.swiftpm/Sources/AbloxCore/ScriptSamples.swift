import Foundation

/// Ready-made `.absc` games Studio offers as a starting point.
///
/// Each is complete and runs as inserted — `ScriptSampleTests` plays every one
/// headlessly — because the first thing anyone does with a sample is press
/// play, and a sample that errors teaches that scripts are broken. Between
/// them they use most of the API, so they double as worked examples.
public struct ScriptSample: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let symbolName: String
    /// The name the file gets when inserted: `duel.absc`.
    public let fileName: String
    public let source: String
}

public enum ScriptSamples {

    public static var all: [ScriptSample] {
        [duel, teams, zombies, menuAndShop, obstacleCourse]
    }

    // MARK: 1v1

    public static var duel: ScriptSample {
        ScriptSample(
            id: "duel",
            title: L("1v1 shooter"),
            summary: L("First person, a rifle each, first to 5 knockouts wins."),
            symbolName: "scope",
            fileName: "duel.absc",
            source: """
            -- \(L("1v1 shooter: first to 5 knockouts wins."))
            let goal = 5

            on start()
              game.respawn_time = 3
              ui_text("goal", "First to " + goal, {at: "top", size: 16})
            end

            on join(p)
              -- \(L("Look through their eyes and hand them a rifle."))
              p.camera = "first"
              p.give("rifle")
              p.kills = 0
              p.ui_text("kills", "Knockouts: 0", {at: "top_left", size: 26, bold: true})
            end

            on death(victim, killer)
              if killer == nil then return end
              killer.kills = killer.kills + 1
              killer.score = killer.kills
              killer.ui_text("kills", "Knockouts: " + killer.kills)
              victim.message(killer.name + " got you!", 2)
              victim.shake(0.5, 0.5)
              if killer.kills >= goal then
                end_round(killer.name + " wins!")
              end
            end
            """
        )
    }

    // MARK: Teams

    public static var teams: ScriptSample {
        ScriptSample(
            id: "teams",
            title: L("Team battle"),
            summary: L("Red against blue, taking turns as people join. Teammates can't hurt each other."),
            symbolName: "person.2.fill",
            fileName: "teams.absc",
            source: """
            -- \(L("Team battle: the first team to 10 knockouts wins."))
            let red = 0
            let blue = 0
            let joined = 0

            func show_scores()
              ui_text("red", "Red " + red, {at: "top_left", color: "red", size: 28, bold: true})
              ui_text("blue", "Blue " + blue, {at: "top_right", color: "blue", size: 28, bold: true})
            end

            on start()
              show_scores()
            end

            on join(p)
              joined = joined + 1
              -- \(L("Odd players are red, even players are blue."))
              if joined % 2 == 1 then
                p.team = "red"
                p.color = "red"
              else
                p.team = "blue"
                p.color = "blue"
              end
              p.give("blaster")
              p.message("You are on the " + p.team + " team", 3)
            end

            on death(victim, killer)
              if killer == nil then return end
              if killer.team == "red" then red = red + 1 else blue = blue + 1 end
              show_scores()
              if red >= 10 then end_round("Red team wins!") end
              if blue >= 10 then end_round("Blue team wins!") end
            end
            """
        )
    }

    // MARK: NPCs

    public static var zombies: ScriptSample {
        ScriptSample(
            id: "zombies",
            title: L("Zombie waves"),
            summary: L("Zombies chase the nearest player. Each wave brings more, and tougher."),
            symbolName: "figure.walk",
            fileName: "zombies.absc",
            source: """
            -- \(L("Zombie waves: survive as long as you can."))
            let wave = 0

            func nearest_player(from)
              let best = nil
              let best_distance = 0
              for p in players() do
                if p.alive then
                  let d = distance(from, p)
                  if best == nil or d < best_distance then
                    best = p
                    best_distance = d
                  end
                end
              end
              return best
            end

            func start_wave()
              wave = wave + 1
              ui_text("wave", "Wave " + wave, {at: "top", size: 30, bold: true})
              announce("Wave " + wave, 2)
              -- \(L("Zombies appear in a ring around the middle of the map."))
              for i in 1 to wave * 3 do
                let angle = random() * 360
                create_npc({name: "Zombie", color: "green", head_color: "#7BC47F",
                            health: 40 + wave * 10, speed: 0.5 + wave * 0.05,
                            position: {x: cos(angle) * 20, y: 3, z: sin(angle) * 20}})
              end
            end

            on start()
              game.respawn_time = 5
              start_wave()
            end

            on join(p)
              p.give("blaster")
            end

            on tick(dt)
              for z in npcs() do
                let target = nearest_player(z)
                if target then
                  z.follow(target)
                  if distance(z, target) < 1.8 then
                    target.damage(15 * dt, z)
                  end
                end
              end
              if len(npcs()) == 0 then
                start_wave()
              end
            end

            on death(victim, killer)
              if victim.is_npc and killer then
                killer.score = killer.score + 1
              end
            end
            """
        )
    }

    // MARK: Screen GUI

    public static var menuAndShop: ScriptSample {
        ScriptSample(
            id: "menu",
            title: L("Title screen and shop"),
            summary: L("A title screen with a Play button, coins over time, and a shop that sells speed and jump."),
            symbolName: "cart.fill",
            fileName: "menu.absc",
            source: """
            -- \(L("A title screen first: no joystick until Play is pressed."))
            on join(p)
              p.controls = false
              p.default_ui = false
              p.coins = 0
              p.ui_panel("title", {w: 420, h: 260, bg: "#000000CC", radius: 24})
              p.ui_text("title_name", "MY GAME", {parent: "title", y: 0.3, size: 44, bold: true, color: "gold"})
              p.ui_button("play", "Play", {parent: "title", y: 0.72, w: 200, h: 56, bg: "green"})
            end

            func open_shop(p)
              p.ui_panel("shop", {at: "right", w: 280, h: 300})
              p.ui_text("shop_title", "Shop", {parent: "shop", y: 0.12, size: 26, bold: true})
              p.ui_button("buy_speed", "Speed x2 (5 coins)", {parent: "shop", y: 0.4, w: 240, size: 16})
              p.ui_button("buy_jump", "Jump x2 (5 coins)", {parent: "shop", y: 0.6, w: 240, size: 16})
              p.ui_button("close_shop", "Close", {parent: "shop", y: 0.85, w: 120, size: 16, bg: "gray"})
            end

            func pay(p, price)
              if p.coins < price then
                p.message("Not enough coins", 1.5)
                return false
              end
              p.coins = p.coins - price
              p.ui_text("coins", "Coins: " + p.coins)
              return true
            end

            on button(p, id)
              if id == "play" then
                p.ui_remove("title")
                p.controls = true
                p.default_ui = true
                p.fade("white", 0.1)
                after(0.2, func() p.fade(nil, 0.6) end)
                p.ui_text("coins", "Coins: 0", {at: "top_left", size: 22, bold: true, color: "gold"})
                p.ui_button("shop_button", "Shop", {at: "bottom_right", bg: "purple"})
                -- \(L("One coin every two seconds."))
                every(2, func()
                  p.coins = p.coins + 1
                  p.ui_text("coins", "Coins: " + p.coins)
                end)
              elif id == "shop_button" then
                open_shop(p)
              elif id == "close_shop" then
                p.ui_remove("shop")
              elif id == "buy_speed" then
                if pay(p, 5) then p.speed = 2 end
              elif id == "buy_jump" then
                if pay(p, 5) then p.jump = 2 end
              end
            end
            """
        )
    }

    // MARK: Building the map

    public static var obstacleCourse: ScriptSample {
        ScriptSample(
            id: "obstacles",
            title: L("Obstacle course builder"),
            summary: L("Builds its own staircase in the sky with a moving step, and times every run."),
            symbolName: "stairs",
            fileName: "obstacles.absc",
            source: """
            -- \(L("Builds its own obstacle course, then times each run."))
            let steps = 12
            let colors = ["red", "orange", "yellow", "green", "blue", "purple"]

            on start()
              world.sky = "#87CEEB"
              for i in 1 to steps do
                create_block({name: "Step " + i, position: {x: i * 3, y: i * 1.2, z: 0},
                              size: {x: 2, y: 0.5, z: 2}, color: colors[(i - 1) % 6 + 1]})
              end
              create_block({name: "Goal", position: {x: (steps + 1) * 3, y: (steps + 1) * 1.2, z: 0},
                            size: 3, color: "gold", material: "neon", tags: ["goal"], behavior: "trigger"})
              -- \(L("Step 6 slides back and forth forever."))
              let mover = block("Step 6")
              every(2, func()
                mover.move(0, 0, 4, 1)
                after(1, func() mover.move(0, 0, -4, 1) end)
              end)
            end

            on join(p)
              p.started = time()
              p.ui_text("timer", "0.0", {at: "top", size: 32, bold: true})
            end

            on tick(dt)
              for p in players() do
                if p.started then p.ui_text("timer", fixed(time() - p.started, 1)) end
              end
            end

            on touch(p, b)
              if contains(b.tags, "goal") and p.started then
                announce(p.name + " finished in " + fixed(time() - p.started, 1) + "s!", 4)
                p.started = nil
                p.teleport(0, 3, 0)
                after(1, func() p.started = time() end)
              end
            end
            """
        )
    }
}

// MARK: - A quick test run, for Studio

/// What happened when a world's scripts ran for a few seconds with nobody at
/// the controls. Studio shows this under its Test button.
public struct ScriptTestReport: Sendable {
    public var problems: [ScriptError] = []
    public var output: [String] = []
    /// Plain sentences about what the first player got and what changed in
    /// the world: a camera, a weapon, screen items, NPCs, new blocks.
    public var notes: [String] = []

    public var isClean: Bool { problems.isEmpty }
}

public extension GameRuntime {

    /// Runs a world's scripts for `seconds` with two idle players, and
    /// reports what they did. No rendering and no network: the same runtime
    /// the host uses, just nobody pressing anything.
    static func testRun(world: WorldDocument, seconds: Double = 5) -> ScriptTestReport {
        var report = ScriptTestReport()
        report.problems = check(world.scripts)
        // Files that do not parse cannot run; `check` has said why.
        if case .failure = ScriptBundle.compile(world.scripts) { return report }

        let game = GameRuntime(world: world, seed: 7)
        let you = PeerID()
        var yourProfile = AvatarProfile.default
        yourProfile.displayName = L("You")
        var otherProfile = AvatarProfile.default
        otherProfile.displayName = L("Guest")

        var effects: [Effect] = []
        effects += game.addPlayer(PlayerSnapshot(peerID: you, profile: yourProfile))
        effects += game.addPlayer(PlayerSnapshot(peerID: PeerID(), profile: otherProfile))
        effects += game.handle(.roundStarted)
        var time = 0.0
        while time < seconds, !game.isRoundOver {
            time += 0.1
            effects += game.advance(to: time)
        }
        let deltas = game.drainWorldDeltas()

        var state = ScriptedPlayerState()
        var messages: [String] = []
        for effect in effects where effect.targetPeerID == nil || effect.targetPeerID == you {
            switch effect.action {
            case let .script(.chat(line)): messages.append(line)
            case let .script(.say(_, name, text)): messages.append(name + ": " + text)
            case let .script(scriptEffect): state.apply(scriptEffect)
            case let .announce(message, _): messages.append(message)
            case let .endRound(message): messages.append(message)
            default: break
            }
        }

        let runtimeErrors = game.drainErrors()
        report.problems += runtimeErrors.filter { error in
            !report.problems.contains { $0.line == error.line && $0.message == error.message && $0.file == error.file }
        }
        report.output = game.drainOutput()

        if state.camera.mode != .thirdPerson {
            report.notes.append(L("Camera: {}", state.camera.mode.rawValue))
        }
        if let weapon = state.weapon { report.notes.append(L("Weapon: {}", weapon.name)) }
        if let health = state.health {
            report.notes.append(L("Health: {} / {}", Int(health.current), Int(health.maximum)))
        }
        if state.movement != .normal {
            report.notes.append(L("Speed ×{}, jump ×{}", ScriptValue.format(Double(state.movement.speed)),
                                  ScriptValue.format(Double(state.movement.jump))))
        }
        if !state.showsControls || !state.showsDefaultUI {
            report.notes.append(L("The joystick or the top bar is hidden."))
        }
        for element in state.ui.prefix(8) {
            switch element.kind {
            case .text: report.notes.append(L("On screen: {}", element.text))
            case .bar: report.notes.append(L("Bar “{}”: {} / {}", element.id, ScriptValue.format(element.value), ScriptValue.format(element.maximum)))
            case .button: report.notes.append(L("Button: {}", element.text))
            case .panel, .image, .input: report.notes.append(L("Screen item: {}", element.id))
            }
        }
        let npcs = game.roster.filter(\.isNPC).count
        if npcs > 0 { report.notes.append(L("NPCs: {}", npcs)) }
        let added = deltas.filter { if case .insert = $0 { return true }; return false }.count
        if added > 0 { report.notes.append(L("Blocks created: {}", added)) }
        for message in messages.suffix(4) {
            report.notes.append(L("Message: {}", message))
        }
        if game.isRoundOver {
            report.notes.append(L("The round ended after {} seconds.", ScriptValue.format(time)))
        }
        return report
    }
}
