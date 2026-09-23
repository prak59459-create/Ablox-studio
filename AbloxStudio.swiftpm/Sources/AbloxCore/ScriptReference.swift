import Foundation

/// The reference beside Studio's script editor: every event and function a
/// script can use, with one sentence each.
///
/// Kept in the core, next to what it describes, so a test can insist that
/// every event, every game function and every standard-library function is
/// listed. A function nobody can find out about might as well not exist.
public enum ScriptReference {

    public struct Entry: Identifiable, Hashable, Sendable {
        public let code: String
        public let explanation: String
        public var id: String { code }

        init(_ code: String, _ explanation: String) {
            self.code = code
            self.explanation = explanation
        }
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public let title: String
        public let symbolName: String
        public let entries: [Entry]
        public var id: String { symbolName }
    }

    public static var sections: [Section] {
        [basics, events, everyone, players, blocks, extras]
    }

    public static var basics: Section {
        Section(title: L("The language"), symbolName: "textformat", entries: [
            Entry("let score = 0", L("Makes a variable. Use it again without “let”.")),
            Entry("if a > 1 then … elif … else … end", L("Does something only when it is true.")),
            Entry("for i in 1 to 10 do … end", L("Counts. “for x in list do” goes through a list.")),
            Entry("while ready do … end", L("Repeats while something is true.")),
            Entry("func add(a, b) return a + b end", L("Makes your own function.")),
            Entry("[1, 2, 3]  {x: 1, y: 2}", L("A list (starts at 1) and a map.")),
            Entry("-- a note", L("A comment. The game ignores it."))
        ])
    }

    public static var events: Section {
        Section(title: L("Events"), symbolName: "bolt.fill", entries: [
            Entry("on start()", L("The round begins.")),
            Entry("on tick(dt)", L("Ten times a second. dt is the time since the last one.")),
            Entry("on join(p)", L("A player arrives. Give them a weapon or a camera here.")),
            Entry("on leave(p)", L("A player leaves.")),
            Entry("on touch(p, block)", L("A player touches a block.")),
            Entry("on tap(p, block)", L("A player taps a block.")),
            Entry("on fire(p)", L("A player fires.")),
            Entry("on hit(victim, attacker, damage)", L("A shot hits someone. Return a number to change the damage.")),
            Entry("on hit_block(p, block)", L("A shot hits a block.")),
            Entry("on death(victim, killer)", L("Someone is knocked out. killer is nil if nobody did it.")),
            Entry("on respawn(p)", L("A knocked-out player comes back.")),
            Entry("on button(p, id)", L("A player presses a screen button."))
        ])
    }

    public static var everyone: Section {
        Section(title: L("Everyone"), symbolName: "person.3.fill", entries: [
            Entry("players()", L("Everyone in the game, as a list.")),
            Entry("announce(\"Go!\", 3)", L("A message for everyone, for some seconds.")),
            Entry("sound(\"goal\")", L("A sound for everyone.")),
            Entry("end_round(\"Red wins!\")", L("Ends the round.")),
            Entry("hud_text(\"id\", \"text\", {at: \"top\", color: \"red\", size: \"large\"})",
                  L("Text on everyone's screen. Use the same id again to change it.")),
            Entry("hud_bar(\"id\", value, max, {…})", L("A bar on everyone's screen.")),
            Entry("hud_button(\"id\", \"label\", {…})", L("A button. Pressing it runs “on button”.")),
            Entry("hud_remove(\"id\")  hud_clear()", L("Takes things off the screen.")),
            Entry("weapon(\"sniper\", {model: \"rifle\", damage: 90, rate: 1, range: 150, ammo: 5, reload: 2, spread: 0})",
                  L("Makes a new weapon. Anything left out comes from the model.")),
            Entry("game.respawn_time = 3", L("Seconds before a knocked-out player returns. -1: only when you call respawn().")),
            Entry("game.friendly_fire = true", L("Lets teammates hurt each other."))
        ])
    }

    public static var players: Section {
        Section(title: L("A player (p)"), symbolName: "figure.stand", entries: [
            Entry("p.name  p.id  p.score  p.team", L("Read them; score and team can be changed.")),
            Entry("p.health  p.max_health  p.alive", L("Health. Setting health to 0 knocks them out.")),
            Entry("p.camera = \"first\"", L("First person (“first”) or behind them (“third”).")),
            Entry("p.give(\"rifle\")  p.take()  p.weapon", L("Weapons: blaster, rifle, shotgun, pistol, or your own.")),
            Entry("p.ammo  p.reload()", L("Rounds left, and reloading.")),
            Entry("p.damage(20)  p.heal(20)  p.kill()", L("Hurt, heal or knock out.")),
            Entry("p.respawn()", L("Back to their spawn point with full health.")),
            Entry("p.teleport(block(\"Spawn\"))", L("Moves them to a block, a player or {x, y, z}.")),
            Entry("p.speed = 2  p.jump = 1.5", L("Walking speed and jump, up to 3 times.")),
            Entry("p.message(\"Hi\", 2)  p.sound(\"hit\")", L("A message or sound for this player only.")),
            Entry("p.hud_text(…)  p.hud_bar(…)  p.hud_button(…)  p.hud_remove(id)  p.hud_clear()",
                  L("Screen items for this player only.")),
            Entry("p.position  p.yaw", L("Where they are, {x, y, z}, and which way they face in degrees.")),
            Entry("p.kills = 0", L("Store your own values on a player."))
        ])
    }

    public static var blocks: Section {
        Section(title: L("Blocks"), symbolName: "cube.fill", entries: [
            Entry("block(\"Door\")", L("The block with that name, or nil.")),
            Entry("blocks(\"coin\")", L("Every block with that tag.")),
            Entry("b.visible = false  b.solid = false", L("Hide it, or let players walk through it.")),
            Entry("b.color = \"red\"", L("Colour by name (red, 青, …) or “#FF8800”.")),
            Entry("b.move(0, 3, 0, 1)", L("Moves it by x, y, z over some seconds.")),
            Entry("b.name  b.tags  b.position", L("What it is called, its tags and where it is."))
        ])
    }

    public static var extras: Section {
        Section(title: L("Handy extras"), symbolName: "wrench.and.screwdriver.fill", entries: [
            Entry("after(2, func() … end)", L("Runs something once, later.")),
            Entry("let t = every(1, func() … end)  cancel(t)", L("Runs something again and again, until cancelled.")),
            Entry("time()", L("Seconds since the round began.")),
            Entry("distance(p, b)", L("Metres between two players, blocks or positions.")),
            Entry("random()  random(1, 6)  random(list)", L("A random number, a dice roll, or a random item.")),
            Entry("print(x)", L("Shows a value in the Test run console.")),
            Entry("len(x)  append(list, x)  remove(list)  contains(list, x)", L("Working with lists.")),
            Entry("keys(map)  join(list, \", \")  split(text, \" \")", L("Maps and text.")),
            Entry("str(x)  num(\"12\")  type(x)", L("Converting between numbers and text.")),
            Entry("floor  ceil  round  abs  sqrt  sin  cos  min  max  clamp", L("Maths. sin and cos take degrees.")),
            Entry("upper  lower  trim  shuffle", L("More text and list helpers."))
        ])
    }
}
