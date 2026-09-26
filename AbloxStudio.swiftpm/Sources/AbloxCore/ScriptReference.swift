import Foundation

/// The reference beside Studio's script editor: every event and function a
/// `.absc` script can use, with one sentence each.
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
        [basics, events, everyone, players, npcs, screen, blocks, extras]
    }

    public static var basics: Section {
        Section(title: L("The language"), symbolName: "textformat", entries: [
            Entry("let score = 0", L("Makes a variable. Use it again without “let”.")),
            Entry("if a > 1 then … elif … else … end", L("Does something only when it is true.")),
            Entry("for i in 1 to 10 do … end", L("Counts. “for x in list do” goes through a list.")),
            Entry("while ready do … end   break   continue", L("Repeats while something is true.")),
            Entry("func add(a, b) return a + b end", L("Makes your own function.")),
            Entry("[1, 2, 3]  {x: 1, y: 2}", L("A list (starts at 1) and a map.")),
            Entry("{x: 1, y: 2, z: 3} + {x: 0, y: 5, z: 0}", L("Positions add, subtract and multiply like arrows.")),
            Entry("-- a note", L("A comment. The game ignores it.")),
            Entry("main.absc  ui.absc  …", L("A world can have many .absc files. They run together; each can have its own “on join”."))
        ])
    }

    public static var events: Section {
        Section(title: L("Events"), symbolName: "bolt.fill", entries: [
            Entry("on start()", L("The round begins.")),
            Entry("on tick(dt)", L("Ten times a second. dt is the time since the last one.")),
            Entry("on join(p)", L("A player arrives. Give them a weapon or a camera here.")),
            Entry("on leave(p)", L("A player leaves.")),
            Entry("on touch(p, block)", L("A player or NPC touches a block.")),
            Entry("on tap(p, block)", L("A player taps a block.")),
            Entry("on fire(p)", L("Someone fires.")),
            Entry("on hit(victim, attacker, damage)", L("A shot hits someone. Return a number to change the damage.")),
            Entry("on hit_block(p, block)", L("A shot hits a block.")),
            Entry("on death(victim, killer)", L("Someone is knocked out. killer is nil if nobody did it.")),
            Entry("on respawn(p)", L("A knocked-out player comes back.")),
            Entry("on button(p, id)", L("A player presses a screen button.")),
            Entry("on input(p, id, text)", L("A player sends text from a text box.")),
            Entry("on chat(p, text)", L("A player says something in the chat — commands, passwords, quizzes.")),
            Entry("on loaded(p)", L("A player's saved data has arrived. Read p.saved here.")),
            Entry("on emote(p, name)", L("Someone waved, danced or sent an emoji stamp: \"wave\", \"dance\", \"stamp:🎉\"…"))
        ])
    }

    public static var everyone: Section {
        Section(title: L("Everyone"), symbolName: "person.3.fill", entries: [
            Entry("players()  npcs()  find_player(\"Mika\")", L("Everyone in the game, the NPCs, or one player by name.")),
            Entry("announce(\"Go!\", 3)  chat(\"Hi\")  sound(\"goal\")", L("A message, a chat line or a sound for everyone.")),
            Entry("fade(\"black\", 1)  fade(nil, 1)  shake(0.5, 1)", L("Fades or shakes everyone's screen.")),
            Entry("end_round(\"Red wins!\")  restart_round()", L("Ends the round, or starts it again from the beginning.")),
            Entry("weapon(\"sniper\", {model: \"rifle\", damage: 90, rate: 1, range: 300, ammo: 5, reload: 2, spread: 0})",
                  L("Makes a new weapon. Anything left out comes from the model.")),
            Entry("game.respawn_time = 3", L("Seconds before a knocked-out player returns. -1: only when you call respawn().")),
            Entry("game.friendly_fire = true", L("Lets teammates hurt each other.")),
            Entry("game.time  game.round_over", L("Seconds since the round began, and whether it has ended."))
        ])
    }

    public static var players: Section {
        Section(title: L("A player (p)"), symbolName: "figure.stand", entries: [
            Entry("p.name  p.id  p.score  p.team  p.is_npc", L("Who they are. Name, score and team can be changed.")),
            Entry("p.health  p.max_health  p.alive", L("Health. Setting health to 0 knocks them out.")),
            Entry("p.position  p.x  p.y  p.z  p.yaw  p.look  p.velocity",
                  L("Where they are and which way they face. Set position to teleport, yaw to turn, velocity to launch.")),
            Entry("p.teleport(block(\"Spawn\"))  p.launch(0, 20, 0)  p.look_at(b)",
                  L("Moves them to a block, a player or {x, y, z}; throws them; turns them to face something.")),
            Entry("p.color  p.head_color  p.leg_color  p.size  p.hat  p.visible",
                  L("How they look, for everyone. size 0.2 to 10; hats: none, cap, crown, antenna, halo.")),
            Entry("p.ride = \"car\"  p.ride_color = \"red\"",
                  L("Draws them riding something: none, car, sports, truck, kart, bike, scooter, jetpack, hoverboard. Only the look — set speed too.")),
            Entry("p.speed  p.jump  p.gravity  p.frozen", L("How they move, up to 10 times. frozen stops them moving.")),
            Entry("p.camera = \"first\"  (\"third\", \"top\", \"fixed\")", L("First person, behind them, looking down from above, or fixed in place.")),
            Entry("p.camera_distance  p.fov  p.camera_look(from, at)  p.camera_reset()",
                  L("How far the camera is, how wide it sees, or a fixed camera looking at something.")),
            Entry("p.controls = false  p.default_ui = false", L("Hides the joystick and buttons, or the top bar and chat.")),
            Entry("p.fade(\"black\", 1)  p.shake(0.5, 1)", L("Fades or shakes this player's screen.")),
            Entry("p.give(\"rifle\")  p.take()  p.weapon  p.ammo  p.reload()",
                  L("Weapons: blaster, rifle, shotgun, pistol, or your own.")),
            Entry("p.damage(20)  p.heal(20)  p.kill()  p.respawn()", L("Hurt, heal, knock out, or bring back.")),
            Entry("p.message(\"Hi\", 2)  p.chat(\"Hi\")  p.sound(\"hit\")", L("A message, chat line or sound for this player only.")),
            Entry("p.kills = 0", L("Store your own values on a player.")),
            Entry("p.save(\"coins\", 120)  p.saved.coins  p.save(\"coins\")",
                  L("Keeps something on the player's iPad for next time, reads it back, or forgets it. p.saved is nil until on loaded."))
        ])
    }

    public static var npcs: Section {
        Section(title: L("NPCs"), symbolName: "figure.walk", entries: [
            Entry("create_npc({name: \"Guard\", position: {x: 0, y: 2, z: 5}, color: \"red\", size: 1.5, health: 200, speed: 0.8, team: \"red\"})",
                  L("Makes a character the game controls. It has everything a player has.")),
            Entry("n.move_to(block(\"Door\"))  n.follow(p)  n.stop()", L("Walks somewhere, keeps following someone, or stops.")),
            Entry("n.jump_now()  n.shoot(p)  n.say(\"Halt!\")", L("Jumps, fires its weapon at someone, or speaks in a bubble over its head.")),
            Entry("p.emote(\"wave\")  n.emote(\"dance\")", L("Plays an emote (wave, dance, clap, cheer, bow, point, laugh, sit) or an emoji stamp on everyone's screen.")),
            Entry("n.destroy()", L("Removes it. A knocked-out NPC is removed unless “on death” brings it back."))
        ])
    }

    public static var screen: Section {
        Section(title: L("Screen GUI"), symbolName: "rectangle.3.group.fill", entries: [
            Entry("ui_text(\"score\", \"Score: 0\", {at: \"top_left\", size: 24, color: \"gold\"})",
                  L("Text on everyone's screen. Call again with the same id to change it.")),
            Entry("ui_button(\"play\", \"Play\", {x: 0.5, y: 0.7, w: 200, h: 56, bg: \"green\"})",
                  L("A button. Pressing it runs “on button”.")),
            Entry("ui_panel(\"menu\", {w: 400, h: 300, bg: \"#000000AA\", radius: 20})",
                  L("A box. Put things inside it with {parent: \"menu\"}; hiding or removing it takes them too.")),
            Entry("ui_image(\"icon\", \"heart.fill\", {size: 40, color: \"red\"})  ui_bar(\"hp\", 50, 100, {w: 200})",
                  L("An icon (any SF Symbol name) or a bar.")),
            Entry("ui_input(\"name\", \"Your name\", {w: 240})", L("A text box. Sending it runs “on input”.")),
            Entry("ui_set(\"score\", {visible: false})  ui_remove(\"menu\")  ui_clear()", L("Changes, removes or clears screen items.")),
            Entry("let t = ui_text(…)   t.text = \"Hi\"   t.visible = false   t.remove()",
                  L("Every ui_ function returns the item, so you can change it directly.")),
            Entry("p.ui_text(…)  p.ui_button(…)  p.ui_panel(…)  p.ui_image(…)  p.ui_bar(…)  p.ui_input(…)  p.ui_set(…)  p.ui_remove(id)  p.ui_clear()",
                  L("The same, on one player's screen only.")),
            Entry("at  x  y  pivot  dx  dy  w  h  color  bg  size  bold  radius  opacity  visible  layer  parent  text  value  max",
                  L("Options. x and y go from 0 to 1 across the screen (or the panel); at: top_left, top, center, bottom_right, …"))
        ])
    }

    public static var blocks: Section {
        Section(title: L("Blocks and the world"), symbolName: "cube.fill", entries: [
            Entry("block(\"Door\")  blocks(\"coin\")  blocks()", L("One block by name, every block with a tag, or every block.")),
            Entry("create_block({shape: \"sphere\", position: {x: 0, y: 5, z: 0}, size: 2, color: \"red\", material: \"neon\", tags: [\"coin\"]})",
                  L("Makes a new block. Shapes: box, sphere, cylinder, cone, plane.")),
            Entry("b.position  b.size  b.rotation  b.color  b.opacity  b.material  b.shape",
                  L("Where it is and what it looks like. All can be changed.")),
            Entry("b.visible  b.solid  b.name  b.tags", L("Hide it, let players walk through it, rename or retag it.")),
            Entry("b.behavior = \"trigger\"", L("What touching it does: trigger, hazard, checkpoint, bounce, collectible and more. Only a block with a behavior reports “on touch”.")),
            Entry("b.move(0, 3, 0, 1)  b.move_to(p, 2)  b.rotate(0, 90, 0)", L("Moves it by x, y, z (or to something) over some seconds, or turns it.")),
            Entry("b.clone()  b.destroy()", L("Copies it, or removes it.")),
            Entry("world.sky = \"#87CEEB\"  world.sky_top  world.sky_bottom  world.light",
                  L("The sky and the light.")),
            Entry("world.gravity = -3  world.sun  world.sun_yaw  world.ground  world.ground_color  world.fall_height",
                  L("Gravity (-9.81 is normal), the sun, the ground plane and the height you fall out of the world."))
        ])
    }

    public static var extras: Section {
        Section(title: L("Handy extras"), symbolName: "wrench.and.screwdriver.fill", entries: [
            Entry("after(2, func() … end)", L("Runs something once, later.")),
            Entry("let t = every(1, func() … end)  cancel(t)", L("Runs something again and again, until cancelled.")),
            Entry("time()", L("Seconds since the round began.")),
            Entry("distance(p, b)", L("Metres between two players, blocks or positions.")),
            Entry("raycast(p, p.look, 50)", L("The first thing along a line: {point, distance, block, player}, or nil.")),
            Entry("random()  random(1, 6)  random(list)", L("A random number, a dice roll, or a random item.")),
            Entry("print(x)", L("Shows a value in the Test run console.")),
            Entry("vec(1, 2, 3)  magnitude(v)  normalize(v)  dot(a, b)  cross(a, b)  lerp(a, b, t)", L("Working with positions and directions.")),
            Entry("len(x)  append(list, x)  insert(list, i, x)  remove(list)  contains(list, x)  index_of(list, x)", L("Working with lists.")),
            Entry("range(1, 5)  slice(list, 2, 3)  reverse(x)  copy(x)  sum(list)  sort(list)  map(list, f)  filter(list, f)",
                  L("More list tools. sort, map and filter take a function.")),
            Entry("keys(map)  join(list, \", \")  split(text, \" \")  replace(text, a, b)  starts_with  ends_with",
                  L("Maps and text.")),
            Entry("str(x)  num(\"12\")  type(x)  fixed(3.14159, 2)", L("Converting between numbers and text.")),
            Entry("floor  ceil  round  abs  sqrt  pow  sin  cos  tan  asin  acos  atan  atan2  log  exp  sign  min  max  clamp  pi",
                  L("Maths. Angles are in degrees.")),
            Entry("upper  lower  trim  shuffle", L("More text and list helpers."))
        ])
    }
}
