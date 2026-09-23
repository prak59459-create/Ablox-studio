import Foundation

/// Ready-made scripts Studio offers as a starting point.
///
/// Each is a complete game that runs as it is — `ScriptSampleTests` plays
/// every one headlessly — because the first thing anyone does with a sample
/// is press play, and a sample that errors teaches that scripts are broken.
public struct ScriptSample: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let symbolName: String
    public let source: String
}

public enum ScriptSamples {

    public static var all: [ScriptSample] {
        [duel, teams, timerAndButtons, coinRush]
    }

    /// A comment line in the reader's language.
    private static func note(_ english: String) -> String {
        "-- " + L(english)
    }

    // MARK: 1v1

    public static var duel: ScriptSample {
        ScriptSample(
            id: "duel",
            title: L("1v1 shooter"),
            summary: L("First person, a rifle each, first to 5 knockouts wins."),
            symbolName: "scope",
            source: """
            \(note("1v1 shooter: first to 5 knockouts wins."))
            let goal = 5

            on start()
              game.respawn_time = 3
              hud_text("goal", "First to " + goal, {at: "top", size: "small"})
            end

            on join(p)
              \(note("Look through their eyes and hand them a rifle."))
              p.camera = "first"
              p.give("rifle")
              p.kills = 0
              p.hud_text("kills", "Knockouts: 0", {at: "top_left", size: "large"})
            end

            on death(victim, killer)
              if killer == nil then
                return
              end
              killer.kills = killer.kills + 1
              killer.score = killer.kills
              killer.hud_text("kills", "Knockouts: " + killer.kills, {at: "top_left", size: "large"})
              victim.message(killer.name + " got you!", 2)
              if killer.kills >= goal then
                end_round(killer.name + " wins!")
              end
            end

            on respawn(p)
              p.message("Back in!", 1)
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
            source: """
            \(note("Team battle: the first team to 10 knockouts wins."))
            let red = 0
            let blue = 0
            let joined = 0

            func show_scores()
              hud_text("red", "Red " + red, {at: "top_left", color: "red", size: "large"})
              hud_text("blue", "Blue " + blue, {at: "top_right", color: "blue", size: "large"})
            end

            on start()
              show_scores()
            end

            on join(p)
              joined = joined + 1
              \(note("Odd players are red, even players are blue."))
              if joined % 2 == 1 then
                p.team = "red"
              else
                p.team = "blue"
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

    // MARK: Screen GUI

    public static var timerAndButtons: ScriptSample {
        ScriptSample(
            id: "timer",
            title: L("Timer and buttons"),
            summary: L("A countdown bar, and buttons that give speed or a weapon."),
            symbolName: "timer",
            source: """
            \(note("A 60 second round with a bar that counts down."))
            let seconds = 60

            on start()
              hud_bar("time", seconds, 60, {at: "top", color: "yellow", size: "large"})
              every(1, func()
                seconds = seconds - 1
                hud_bar("time", seconds, 60, {at: "top", color: "yellow", size: "large"})
                if seconds <= 0 then
                  end_round("Time's up!")
                end
              end)
            end

            on join(p)
              \(note("Buttons appear on the right of the screen."))
              p.hud_button("fast", "Run fast", {color: "green"})
              p.hud_button("arm", "Get a pistol", {color: "orange"})
            end

            on button(p, id)
              if id == "fast" then
                p.speed = 2
                p.message("Speed up for 5 seconds!", 2)
                after(5, func() p.speed = 1 end)
              elif id == "arm" then
                p.give("pistol")
                p.hud_remove("arm")
              end
            end
            """
        )
    }

    // MARK: Collecting

    public static var coinRush: ScriptSample {
        ScriptSample(
            id: "coins",
            title: L("Coin rush"),
            summary: L("Touch blocks tagged “coin” to collect them. Most coins in 90 seconds wins."),
            symbolName: "star.circle.fill",
            source: """
            \(note("Tag some blocks “coin” in the Inspector first."))
            let time_left = 90

            on start()
              hud_text("coins", "Coins left: " + len(blocks("coin")), {at: "top"})
              every(1, func()
                time_left = time_left - 1
                hud_text("clock", time_left + "s", {at: "top_right", size: "large"})
                if time_left <= 0 then
                  let best = nil
                  for p in players() do
                    if best == nil or p.score > best.score then best = p end
                  end
                  if best then end_round(best.name + " wins!") else end_round() end
                end
              end)
            end

            on touch(p, b)
              if contains(b.tags, "coin") and b.visible then
                b.visible = false
                p.score = p.score + 1
                p.sound("collect")
                let left = 0
                for c in blocks("coin") do
                  if c.visible then left = left + 1 end
                end
                hud_text("coins", "Coins left: " + left, {at: "top"})
              end
            end
            """
        )
    }
}

// MARK: - A quick test run, for Studio

/// What happened when a script was run for a few seconds with nobody at the
/// controls. Studio shows this under its Test button.
public struct ScriptTestReport: Sendable {
    public var problems: [ScriptError] = []
    public var output: [String] = []
    /// Plain sentences about what the first player got: a camera, a weapon,
    /// items on screen, messages.
    public var notes: [String] = []

    public var isClean: Bool { problems.isEmpty }
}

public extension GameRuntime {

    /// Runs a world's script for `seconds` with two idle players, and reports
    /// what it did. No rendering and no network: the same runtime the host
    /// uses, just nobody pressing anything.
    static func testRun(world: WorldDocument, seconds: Double = 5) -> ScriptTestReport {
        var report = ScriptTestReport()
        let source = world.script ?? ""
        report.problems = check(source)
        // A script that does not parse cannot run; `check` has already said
        // why, and there is nothing more to learn.
        guard (try? ScriptParser.parse(source)) != nil else { return report }

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

        var state = ScriptedPlayerState()
        var messages: [String] = []
        for effect in effects where effect.targetPeerID == nil || effect.targetPeerID == you {
            switch effect.action {
            case let .script(scriptEffect): state.apply(scriptEffect)
            case let .announce(message, _): messages.append(message)
            case let .endRound(message): messages.append(message)
            default: break
            }
        }

        let runtimeErrors = game.drainErrors()
        report.problems += runtimeErrors.filter { error in
            !report.problems.contains { $0.line == error.line && $0.message == error.message }
        }
        report.output = game.drainOutput()

        if state.camera == .firstPerson { report.notes.append(L("Camera: first person")) }
        if let weapon = state.weapon { report.notes.append(L("Weapon: {}", weapon.name)) }
        if let health = state.health {
            report.notes.append(L("Health: {} / {}", Int(health.current), Int(health.maximum)))
        }
        if state.speedMultiplier != 1 || state.jumpMultiplier != 1 {
            report.notes.append(L("Speed ×{}, jump ×{}", ScriptValue.format(Double(state.speedMultiplier)),
                                  ScriptValue.format(Double(state.jumpMultiplier))))
        }
        for element in state.hud.prefix(6) {
            switch element.kind {
            case let .text(text): report.notes.append(L("On screen: {}", text))
            case let .bar(value, maximum): report.notes.append(L("Bar “{}”: {} / {}", element.id, ScriptValue.format(value), ScriptValue.format(maximum)))
            case let .button(label): report.notes.append(L("Button: {}", label))
            }
        }
        for message in messages.suffix(4) {
            report.notes.append(L("Message: {}", message))
        }
        if game.isRoundOver {
            report.notes.append(L("The round ended after {} seconds.", ScriptValue.format(time)))
        }
        return report
    }
}
